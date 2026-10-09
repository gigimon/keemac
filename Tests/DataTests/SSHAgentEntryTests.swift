@testable import Data
import Domain
import Foundation
@testable import UI
import XCTest

/// SSH agent settings stored the KeeAgent / KeePassXC way and kept through edits.
final class SSHAgentEntryTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// What KeePassXC 2.7 writes into `KeeAgent.settings` (UTF-16 with a BOM).
    private static let keePassXCSettings: Data = {
        let xml = """
        <?xml version="1.0" encoding="UTF-16"?>
        <EntrySettings xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <AllowUseOfSshKey>true</AllowUseOfSshKey>
            <AddAtDatabaseOpen>true</AddAtDatabaseOpen>
            <RemoveAtDatabaseClose>true</RemoveAtDatabaseClose>
            <UseConfirmConstraintWhenAdding>false</UseConfirmConstraintWhenAdding>
            <UseLifetimeConstraintWhenAdding>true</UseLifetimeConstraintWhenAdding>
            <LifetimeConstraintDuration>3600</LifetimeConstraintDuration>
            <Location>
                <SelectedType>attachment</SelectedType>
                <AttachmentName>id_ed25519</AttachmentName>
                <SaveAttachmentToTempFile>false</SaveAttachmentToTempFile>
                <FileName />
            </Location>
        </EntrySettings>
        """
        return Data([0xFF, 0xFE]) + xml.data(using: .utf16LittleEndian)!
    }()

    func testReadsKeePassXCSettings() throws {
        let settings = try XCTUnwrap(VaultSSHAgentSettings(keeAgentData: Self.keePassXCSettings))
        XCTAssertTrue(settings.isEnabled)
        XCTAssertEqual(settings.keyAttachmentName, "id_ed25519")
        XCTAssertTrue(settings.useLifetimeConstraint)
        XCTAssertEqual(settings.lifetimeSeconds, 3600)
        let reread = try XCTUnwrap(VaultSSHAgentSettings(keeAgentData: settings.keeAgentData))
        XCTAssertEqual(reread, settings, "written back the way it was read")
        XCTAssertNil(VaultSSHAgentSettings(keeAgentData: Data("not xml".utf8)))
    }

    func testSettingsSurviveSavingAndOrdinaryEdits() async throws {
        let url = directory.appendingPathComponent("Keys.kdbx")
        let kdf = VaultDatabaseSettings(kdf: .argon2id, argonIterations: 1, argonMemoryMiB: 8, argonParallelism: 1)
        let loader = KeePassKitVaultLoader()
        _ = try await loader.createVault(options: VaultCreationOptions(fileURL: url, name: "Keys", masterPassword: "pw", keyDerivation: kdf))

        let keyData = Data("-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----\n".utf8)
        var settings = VaultSSHAgentSettings(keyAttachmentName: "deploy")
        settings.hosts = [VaultSSHHost(pattern: "prod.example.com"), VaultSSHHost(pattern: "*.internal", learnedAt: Date(timeIntervalSince1970: 1_800_000_000))]
        settings.confirmation = .everyTime
        var vault = try await loader.createEntry(inGroupPath: nil, form: VaultEntryForm(
            title: "Deploy key",
            attachments: [VaultAttachment(name: "deploy", data: keyData)],
            entryType: .sshKey,
            sshAgent: settings
        ))
        var entry = try XCTUnwrap(vault.entries.first { $0.title == "Deploy key" })
        XCTAssertEqual(entry.attachments.map(\.name), ["deploy"], "KeeAgent.settings isn't listed as a file")
        XCTAssertEqual(entry.sshAgent, settings)

        // An edit that doesn't touch the agent keeps it.
        var form = VaultEntryForm(entry: entry)
        form.notes = "rotated in 2026"
        vault = try await loader.updateEntry(id: entry.id, form: form)
        entry = try XCTUnwrap(vault.entries.first { $0.id == entry.id })
        XCTAssertEqual(entry.sshAgent, settings)

        let reopened = try await KeePassKitVaultLoader().loadVault(from: url, masterPassword: "pw", keyFileURL: nil)
        XCTAssertEqual(reopened.entries.first { $0.id == entry.id }?.sshAgent, settings, "saved in the file")

        // Turning it off for good removes both parts.
        form = VaultEntryForm(entry: entry)
        form.sshAgent = nil
        vault = try await loader.updateEntry(id: entry.id, form: form)
        XCTAssertNil(vault.entries.first { $0.id == entry.id }?.sshAgent)
    }
}
