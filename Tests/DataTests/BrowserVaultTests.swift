import AppKit
import CryptoKit
@testable import Data
import Domain
import Foundation
import XCTest

final class BrowserVaultTests: XCTestCase {
    private var directory: URL!
    private var vaultURL: URL!
    private let password = "browser-test"

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        vaultURL = directory.appendingPathComponent("Browser.kdbx")
        let fastKDF = VaultDatabaseSettings(kdf: .argon2id, argonIterations: 1, argonMemoryMiB: 8, argonParallelism: 1)
        _ = try await KeePassKitVaultLoader().createVault(options: VaultCreationOptions(
            fileURL: vaultURL,
            name: "Browser",
            masterPassword: password,
            keyDerivation: fastKDF
        ))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func open() async throws -> (KeePassKitVaultLoader, LoadedVault) {
        let loader = KeePassKitVaultLoader()
        let vault = try await loader.loadVault(from: vaultURL, masterPassword: password, keyFileURL: nil)
        return (loader, vault)
    }

    func testDatabaseHashIsKeePassXCs() async throws {
        let (loader, vault) = try await open()
        let root = try XCTUnwrap(vault.groups.first { !$0.path.contains(".") && !$0.isTrash })
        let hex = root.id.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let expected = SHA256.hash(data: Data(hex.utf8)).map { String(format: "%02x", $0) }.joined()
        let hash = await loader.browserDatabaseHash()
        XCTAssertEqual(hash, expected)
    }

    func testAssociationsAreSavedInDatabase() async throws {
        let (loader, _) = try await open()
        _ = try await loader.storeBrowserAssociation(id: "chrome-mac", key: "aWRLZXk=", created: "03.10.2026, 01:00")

        let (reopened, _) = try await open()
        let associations = await reopened.browserAssociations()
        XCTAssertEqual(associations, [VaultBrowserAssociation(id: "chrome-mac", key: "aWRLZXk=", created: "03.10.2026, 01:00")])

        _ = try await reopened.removeBrowserAssociation(id: "chrome-mac")
        let removed = await (try await open()).0.browserAssociations()
        XCTAssertTrue(removed.isEmpty)
    }

    func testAssociationSurvivesMergeWithAnotherDevice() async throws {
        let (mac, _) = try await open()
        let (phone, _) = try await open()

        _ = try await mac.storeBrowserAssociation(id: "firefox", key: "a2V5", created: "today")
        _ = try await phone.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "From Phone"))

        let (reopened, vault) = try await open()
        XCTAssertTrue(vault.entries.contains { $0.title == "From Phone" })
        let associations = await reopened.browserAssociations()
        XCTAssertEqual(associations.map(\.id), ["firefox"])
    }

    func testCandidatesAndRememberedAccess() async throws {
        let (loader, _) = try await open()
        _ = try await loader.createEntry(inGroupPath: nil, form: VaultEntryForm(
            title: "Mail",
            username: "anna",
            password: "secret",
            url: "https://mail.example.com",
            customFields: [
                VaultCustomFieldForm(key: "KP2A_URL", value: "https://webmail.example.net", isProtected: false),
                VaultCustomFieldForm(key: "KPH: pin", value: "1234", isProtected: true)
            ]
        ))
        var vault = try await loader.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Old", url: "example.org"))
        let old = try XCTUnwrap(vault.entries.first { $0.title == "Old" })
        vault = try await loader.deleteEntry(id: old.id)

        let candidates = await loader.browserCandidates()
        XCTAssertEqual(candidates.map(\.title), ["Mail"], "entries in the recycle bin are left out")
        let mail = try XCTUnwrap(candidates.first)
        XCTAssertEqual(mail.username, "anna")
        XCTAssertEqual(mail.password, "secret")
        XCTAssertEqual(mail.additionalURLs, ["https://webmail.example.net"])
        XCTAssertEqual(mail.kphFields.map(\.key), ["KPH: pin"])
        XCTAssertNil(mail.access)

        let saved = try await loader.rememberBrowserAccess(allowed: [mail.id], denied: [], hosts: ["mail.example.com", ""])
        XCTAssertNotNil(saved)
        let historyCount = saved?.entries.first { $0.id == mail.id }?.history.count
        XCTAssertEqual(historyCount, 0, "remembering access doesn't add history")

        let (reopened, _) = try await open()
        let access = await reopened.browserCandidates().first?.access
        XCTAssertEqual(access, BrowserAccessConfig(allowedHosts: ["mail.example.com"]))

        let noHosts = try await reopened.rememberBrowserAccess(allowed: [mail.id], denied: [], hosts: [])
        XCTAssertNil(noHosts)
    }

    func testAddBrowserLoginUsesDefaultGroup() async throws {
        let (loader, _) = try await open()
        let first = try await loader.addBrowserLogin(VaultBrowserNewLogin(
            title: "example.com", url: "https://example.com/login", username: "anna", password: "one",
            groupID: nil, allowedHosts: ["example.com", "sso.example.com"]
        ))
        let second = try await loader.addBrowserLogin(VaultBrowserNewLogin(
            title: "other.com", url: "https://other.com", username: "bob", password: "two", groupID: nil, allowedHosts: []
        ))

        let browserGroups = second.vault.groups.filter { $0.title == "KeePassXC-Browser Passwords" }
        XCTAssertEqual(browserGroups.count, 1, "the default group is created once")
        let entries = second.vault.entries.filter { [first.entryID, second.entryID].contains($0.id) }
        XCTAssertEqual(Set(entries.map(\.groupPath)), [browserGroups[0].path])

        let candidates = await loader.browserCandidates()
        let saved = try XCTUnwrap(candidates.first { $0.id == first.entryID })
        XCTAssertEqual(saved.username, "anna")
        XCTAssertEqual(saved.url, "https://example.com/login")
        XCTAssertEqual(saved.access?.allowedHosts, ["example.com", "sso.example.com"])
        XCTAssertNil(candidates.first { $0.id == second.entryID }?.access)
    }

    func testAddBrowserLoginIntoChosenGroupAndGroupTree() async throws {
        let (loader, _) = try await open()
        let created = try await loader.createBrowserGroup(atPath: ["Web", "Shops"])
        XCTAssertEqual(created.group.title, "Shops")
        let again = try await loader.createBrowserGroup(atPath: ["Web", "Shops"])
        XCTAssertEqual(again.group.id, created.group.id, "existing groups are reused")
        let found = await loader.browserGroup(atPath: ["Web", "Shops"])
        XCTAssertEqual(found?.id, created.group.id)
        let missing = await loader.browserGroup(atPath: ["Web", "Nope"])
        XCTAssertNil(missing)

        let added = try await loader.addBrowserLogin(VaultBrowserNewLogin(
            title: "shop", url: "https://shop.example", username: "u", password: "p", groupID: created.group.id, allowedHosts: []
        ))
        let entry = try XCTUnwrap(added.vault.entries.first { $0.id == added.entryID })
        XCTAssertTrue(entry.groupPath.hasSuffix("Web.Shops"))

        let tree = await loader.browserGroupTree()
        let web = try XCTUnwrap(tree?.children.first { $0.title == "Web" })
        XCTAssertEqual(web.children.map(\.title), ["Shops"])
        XCTAssertFalse(tree?.children.contains { $0.title == "Recycle Bin" } ?? true)
    }

    func testUpdateBrowserLoginFollowsPasswordReference() async throws {
        let (loader, _) = try await open()
        let vault = try await loader.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Original", username: "anna", password: "old"))
        let original = try XCTUnwrap(vault.entries.first { $0.title == "Original" })
        let copy = try await loader.duplicateEntry(id: original.id, referencingCredentials: true)

        let target = await loader.browserLoginTarget(for: copy.entryID)
        XCTAssertEqual(target?.id, original.id, "the password lives in the original")
        XCTAssertEqual(target?.password, "old")

        let other = try await loader.browserLoginTarget(for: original.id)
        XCTAssertEqual(other?.usernameIsReference, false)

        let updated = try await loader.updateBrowserLogin(id: copy.entryID, username: "anna2", password: "new")
        let source = try XCTUnwrap(updated.entries.first { $0.id == original.id })
        XCTAssertEqual(source.password, "new")
        XCTAssertEqual(source.username, "anna2")
        XCTAssertEqual(source.history.count, 1, "the old password goes to history")
        let referencing = try XCTUnwrap(updated.entries.first { $0.id == copy.entryID })
        XCTAssertEqual(referencing.password, "new")
    }

    func testSetBrowserEntryIconReusesIdenticalIcons() async throws {
        let (loader, _) = try await open()
        let first = try await loader.addBrowserLogin(VaultBrowserNewLogin(title: "a", url: "https://a.example", username: "", password: "", groupID: nil, allowedHosts: []))
        let second = try await loader.addBrowserLogin(VaultBrowserNewLogin(title: "b", url: "https://b.example", username: "", password: "", groupID: nil, allowedHosts: []))
        let png = try XCTUnwrap(Self.samplePNG())

        _ = try await loader.setBrowserEntryIcon(id: first.entryID, imageData: png)
        let vault = try await loader.setBrowserEntryIcon(id: second.entryID, imageData: png)
        let icons = vault?.entries.filter { [first.entryID, second.entryID].contains($0.id) }.compactMap(\.iconPNGData)
        XCTAssertEqual(icons?.count, 2)

        let (_, reopened) = try await open()
        let entry = try XCTUnwrap(reopened.entries.first { $0.id == first.entryID })
        XCTAssertNotNil(entry.iconPNGData)
        XCTAssertTrue(entry.history.isEmpty, "setting the icon doesn't add history")

        let gone = try await loader.setBrowserEntryIcon(id: UUID(), imageData: png)
        XCTAssertNil(gone)
    }

    private static func samplePNG() -> Data? {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
                                      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        bitmap?.setColor(.systemBlue, atX: 1, y: 1)
        return bitmap?.representation(using: .png, properties: [:])
    }
}
