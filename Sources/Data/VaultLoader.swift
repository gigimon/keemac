import Domain
import Foundation

public struct LoadedVault: Sendable, Equatable {
    public let summary: VaultSummary
    public let groups: [VaultGroup]
    public let entries: [VaultEntry]

    public init(summary: VaultSummary, groups: [VaultGroup], entries: [VaultEntry]) {
        self.summary = summary
        self.groups = groups
        self.entries = entries
    }
}

public protocol VaultLoading: Sendable {
    func loadVault(from fileURL: URL, masterPassword: String, keyFileURL: URL?) async throws -> LoadedVault
}

public protocol VaultEditing: Sendable {
    func createEntry(inGroupPath groupPath: String?, form: VaultEntryForm) async throws -> LoadedVault
    func updateEntry(id: UUID, form: VaultEntryForm) async throws -> LoadedVault
    func deleteEntry(id: UUID) async throws -> LoadedVault
}

public protocol VaultSessionControlling: Sendable {
    func clearLoadedSession() async
}
