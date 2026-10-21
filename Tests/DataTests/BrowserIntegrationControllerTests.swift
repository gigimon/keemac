import BrowserIntegration
@testable import Data
import Darwin
import Domain
import Foundation
@testable import UI
import XCTest

@MainActor
private final class FakePrompts: BrowserPrompting {
    var connectionName: String? = "chrome-mac"
    var accessAnswer: ([VaultBrowserCandidate]) -> BrowserAccessAnswer? = { _ in nil }
    var updateAnswer = true
    var groupAnswer = true
    var generatedPassword: String? = "Gen3rated!"
    var holdsUnlock = false
    private var unlockContinuation: CheckedContinuation<Void, Never>?

    private(set) var connectionRequests: [(databaseName: String, existingNames: Set<String>)] = []
    private(set) var accessRequests: [(site: String, titles: [String])] = []
    private(set) var updateRequests: [(site: String, title: String, newUsername: String?, changesPassword: Bool)] = []
    private(set) var groupRequests: [String] = []
    private(set) var unlockRequests = 0
    private(set) var cancelCount = 0

    func askConnectionName(databaseName: String, existingNames: Set<String>) async -> String? {
        connectionRequests.append((databaseName, existingNames))
        return connectionName
    }

    func askAccess(site: String, entries: [VaultBrowserCandidate]) async -> BrowserAccessAnswer? {
        accessRequests.append((site, entries.map(\.title)))
        return accessAnswer(entries)
    }

    func confirmUpdate(site: String, target: VaultBrowserLoginTarget, newUsername: String?, changesPassword: Bool) async -> Bool {
        updateRequests.append((site, target.title, newUsername, changesPassword))
        return updateAnswer
    }

    func confirmNewGroup(path: String) async -> Bool {
        groupRequests.append(path)
        return groupAnswer
    }

    func askUnlock(viewModel: AppViewModel) async -> Bool {
        unlockRequests += 1
        if holdsUnlock {
            await withCheckedContinuation { unlockContinuation = $0 }
        }
        return false
    }

    func releaseUnlock() {
        unlockContinuation?.resume()
        unlockContinuation = nil
    }

    func generatePassword() async -> String? {
        generatedPassword
    }

    func cancelAll() {
        cancelCount += 1
    }
}

/// A real database opened in an `AppViewModel`, with a controller that never touches the user's socket or browsers.
@MainActor
private final class Fixture {
    let directory: URL
    let url: URL
    let password = "pw"
    let socketPath: String
    let manifestDirectory: URL
    let suiteName = "KeeMacBrowserControllerTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let settings: AppSettingsStore
    let loader = KeePassKitVaultLoader()
    let model: AppViewModel
    let prompts = FakePrompts()
    let controller: BrowserIntegrationController
    private(set) var ids: [String: UUID] = [:]

    init(entries: [VaultEntryForm] = [], proxyURL: URL? = nil, configure: Bool = true) async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("Browser.kdbx")
        socketPath = FileManager.default.temporaryDirectory.appendingPathComponent("kmc-\(UUID().uuidString.prefix(8)).sock").path
        manifestDirectory = directory.appendingPathComponent("Application Support", isDirectory: true)

        let kdf = VaultDatabaseSettings(kdf: .argon2id, argonIterations: 1, argonMemoryMiB: 8, argonParallelism: 1)
        let creator = KeePassKitVaultLoader()
        var vault = try await creator.createVault(options: VaultCreationOptions(fileURL: url, name: "Browser", masterPassword: password, keyDerivation: kdf))
        for form in entries {
            vault = try await creator.createEntry(inGroupPath: nil, form: form)
            ids[form.title] = vault.entries.first { $0.title == form.title }?.id
        }

        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        settings = AppSettingsStore(userDefaults: defaults)
        settings.setTouchIDEnabled(false, for: url)
        settings.setExpiryNotificationsEnabled(false, for: url)
        model = AppViewModel(vaultLoader: loader, settingsStore: settings, userDefaults: defaults)
        controller = BrowserIntegrationController(
            settings: settings,
            prompts: prompts,
            socketPath: socketPath,
            manifestDirectory: manifestDirectory,
            proxyURL: proxyURL
        )
        if configure {
            controller.configure(viewModel: model)
        }
        model.selectVault(url: url)
        await model.unlock(masterPassword: password)
        XCTAssertTrue(model.loadState.isUnlocked)
    }

    func id(_ title: String) throws -> UUID {
        try XCTUnwrap(ids[title])
    }

    var vault: LoadedVault? {
        if case .loaded(let vault) = model.loadState {
            return vault
        }
        return nil
    }

    /// The file as another KeeMac would read it.
    func reopen() async throws -> (KeePassKitVaultLoader, LoadedVault) {
        let loader = KeePassKitVaultLoader()
        let vault = try await loader.loadVault(from: url, masterPassword: password, keyFileURL: nil)
        return (loader, vault)
    }

    func storedAssociations() async throws -> [VaultBrowserAssociation] {
        try await reopen().0.browserAssociations()
    }

    func storedCandidates() async throws -> [VaultBrowserCandidate] {
        try await reopen().0.browserCandidates()
    }

    func storedEntry(_ predicate: (VaultEntry) -> Bool) async throws -> VaultEntry {
        let entry = try await reopen().1.entries.first(where: predicate)
        return try XCTUnwrap(entry)
    }

    func lock() async {
        model.lockVault(reason: .quickAccess)
        await model.finishPendingLock()
    }

    func tearDown() async {
        controller.shutdown()
        await lock()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
        unlink(socketPath)
    }
}

/// Waits for a condition the main actor reaches asynchronously (notifications, detached tasks).
@MainActor
private func waitUntil(
    _ description: String,
    timeout: Duration = .seconds(5),
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () async -> Bool
) async {
    let deadline = ContinuousClock.now + timeout
    while !(await condition()) {
        guard ContinuousClock.now < deadline else {
            XCTFail("Timed out waiting: \(description)", file: file, line: line)
            return
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

/// Reads `length + JSON` frames from a socket on its own thread.
private final class SocketFrameReader: @unchecked Sendable {
    private let descriptor: Int32
    private let lock = NSLock()
    private var frames: [Data] = []
    private var isClosed = false
    private var waiter: (token: Int, continuation: CheckedContinuation<Data?, Never>)?
    private var nextToken = 0

    init?(path: String) {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard descriptor >= 0, bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            return nil
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            bytes.withUnsafeBytes { buffer.copyMemory(from: $0) }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(descriptor)
            return nil
        }
        self.descriptor = descriptor
        Thread { [self] in readLoop() }.start()
    }

    func close() {
        shutdown(descriptor, SHUT_RDWR)
    }

    /// Sends one frame. `connect` returns before the server accepts, so a reply to it shows
    /// the server holds the connection and broadcasts reach it.
    func send(_ request: [String: Any]) throws {
        var frame = Data()
        let body = try JSONSerialization.data(withJSONObject: request)
        var length = UInt32(body.count)
        frame.append(Data(bytes: &length, count: 4))
        frame.append(body)
        let written = frame.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        XCTAssertEqual(written, frame.count)
    }

    /// The next frame as JSON, nil on timeout or when the server closed the connection.
    func next(timeout: Duration = .seconds(5)) async -> [String: Any]? {
        let data: Data? = await withCheckedContinuation { continuation in
            lock.lock()
            defer { lock.unlock() }
            if !frames.isEmpty {
                continuation.resume(returning: frames.removeFirst())
                return
            }
            if isClosed {
                continuation.resume(returning: nil)
                return
            }
            nextToken += 1
            let token = nextToken
            waiter = (token, continuation)
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(Int(timeout.components.seconds * 1000))) { [self] in
                lock.lock()
                defer { lock.unlock() }
                if let waiter, waiter.token == token {
                    self.waiter = nil
                    waiter.continuation.resume(returning: nil)
                }
            }
        }
        return data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    private func readLoop() {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(descriptor, &chunk, chunk.count)
            guard count > 0 else {
                break
            }
            buffer.append(contentsOf: chunk[0..<count])
            while buffer.count >= 4 {
                let length = Int(buffer.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
                guard buffer.count >= 4 + length else {
                    break
                }
                deliver(Data(buffer.dropFirst(4).prefix(length)))
                buffer = Data(buffer.dropFirst(4 + length))
            }
        }
        Darwin.close(descriptor)
        lock.lock()
        isClosed = true
        let waiter = waiter
        self.waiter = nil
        lock.unlock()
        waiter?.continuation.resume(returning: nil)
    }

    private func deliver(_ frame: Data) {
        lock.lock()
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.continuation.resume(returning: frame)
        } else {
            frames.append(frame)
            lock.unlock()
        }
    }
}

@MainActor
final class BrowserIntegrationControllerTests: XCTestCase {
    private var fixture: Fixture?

    override func tearDown() async throws {
        await fixture?.tearDown()
        fixture = nil
    }

    private func makeFixture(_ entries: [VaultEntryForm] = [], proxyURL: URL? = nil, configure: Bool = true) async throws -> Fixture {
        let fixture = try await Fixture(entries: entries, proxyURL: proxyURL, configure: configure)
        self.fixture = fixture
        return fixture
    }

    private static let mail = VaultEntryForm(title: "Mail", username: "anna", password: "secret", url: "https://mail.example.com")
    private static let mailQuery = BrowserLoginQuery(siteURL: "https://mail.example.com/login", formURL: "https://mail.example.com/session", httpAuth: false)

    // MARK: - Associations

    func testAssociateStoresNamedConnectionInFile() async throws {
        let fixture = try await makeFixture()
        let controller = fixture.controller

        let name = await controller.associateBrowser(identificationKey: "aWRLZXk=")
        XCTAssertEqual(name, "chrome-mac")
        XCTAssertEqual(fixture.prompts.connectionRequests.first?.databaseName, "Browser.kdbx")
        XCTAssertEqual(fixture.prompts.connectionRequests.first?.existingNames, [])
        XCTAssertEqual(controller.associations.map(\.id), ["chrome-mac"])
        let key = await controller.browserAssociationKey(for: "chrome-mac")
        XCTAssertEqual(key, "aWRLZXk=")

        fixture.prompts.connectionName = "firefox"
        _ = await controller.associateBrowser(identificationKey: "Zm94")
        XCTAssertEqual(fixture.prompts.connectionRequests.last?.existingNames, ["chrome-mac"], "the prompt knows names already taken")

        let stored = try await fixture.storedAssociations()
        XCTAssertEqual(Set(stored.map(\.id)), ["chrome-mac", "firefox"])
        XCTAssertEqual(stored.first { $0.id == "chrome-mac" }?.key, "aWRLZXk=")
        XCTAssertNotNil(stored.first?.created)

        let association = try XCTUnwrap(controller.associations.first { $0.id == "chrome-mac" })
        await controller.removeAssociation(association)
        XCTAssertEqual(controller.associations.map(\.id), ["firefox"])
        let remaining = try await fixture.storedAssociations()
        XCTAssertEqual(remaining.map(\.id), ["firefox"])
        let removedKey = await controller.browserAssociationKey(for: "chrome-mac")
        XCTAssertNil(removedKey)
    }

    func testCancelledAssociationStoresNothing() async throws {
        let fixture = try await makeFixture()
        fixture.prompts.connectionName = nil

        let name = await fixture.controller.associateBrowser(identificationKey: "aWRLZXk=")
        XCTAssertNil(name)
        XCTAssertEqual(fixture.prompts.connectionRequests.count, 1)
        XCTAssertTrue(fixture.controller.associations.isEmpty)
        let stored = try await fixture.storedAssociations()
        XCTAssertTrue(stored.isEmpty)
    }

    func testDatabaseHashIsTheLoaders() async throws {
        let fixture = try await makeFixture()
        let expected = await fixture.loader.browserDatabaseHash()
        let hash = await fixture.controller.browserDatabaseHash()
        XCTAssertNotNil(hash)
        XCTAssertEqual(hash, expected)
    }

    // MARK: - Logins and access

    func testLoginsForMatchingURLsAfterConfirmation() async throws {
        let fixture = try await makeFixture([
            Self.mail,
            VaultEntryForm(title: "Other", username: "x", password: "y", url: "https://other.org")
        ])
        fixture.prompts.accessAnswer = { entries in BrowserAccessAnswer(allowed: Set(entries.map(\.id)), remember: false) }

        let logins = await fixture.controller.browserLogins(for: Self.mailQuery)
        XCTAssertEqual(logins.map(\.name), ["Mail"])
        let login = try XCTUnwrap(logins.first)
        XCTAssertEqual(login.login, "anna")
        XCTAssertEqual(login.password, "secret")
        XCTAssertEqual(login.uuid, try fixture.id("Mail"))
        XCTAssertEqual(login.group, "Browser")
        XCTAssertNil(login.totp)
        XCTAssertFalse(login.isExpired)
        XCTAssertEqual(fixture.prompts.accessRequests.first?.site, "mail.example.com")
        XCTAssertEqual(fixture.prompts.accessRequests.first?.titles, ["Mail"])

        _ = await fixture.controller.browserLogins(for: Self.mailQuery)
        XCTAssertEqual(fixture.prompts.accessRequests.count, 2, "an answer that isn't remembered is asked again")
        let access = try await fixture.storedCandidates().first { $0.title == "Mail" }?.access
        XCTAssertNil(access)

        fixture.prompts.accessAnswer = { _ in nil }
        let cancelled = await fixture.controller.browserLogins(for: Self.mailQuery)
        XCTAssertTrue(cancelled.isEmpty)

        let none = await fixture.controller.browserLogins(for: BrowserLoginQuery(siteURL: "https://nothing.test/", formURL: "", httpAuth: false))
        XCTAssertTrue(none.isEmpty)
        XCTAssertEqual(fixture.prompts.accessRequests.count, 3, "no prompt without matching entries")
    }

    func testRememberedAnswerIsSavedIntoFile() async throws {
        let fixture = try await makeFixture([
            Self.mail,
            VaultEntryForm(title: "Mail (old)", username: "anna.old", password: "old", url: "https://mail.example.com")
        ])
        let mailID = try fixture.id("Mail")
        let oldID = try fixture.id("Mail (old)")
        fixture.prompts.accessAnswer = { _ in BrowserAccessAnswer(allowed: [mailID], remember: true) }
        let query = BrowserLoginQuery(siteURL: "https://mail.example.com/login", formURL: "https://auth.example.com/session", httpAuth: false)

        let logins = await fixture.controller.browserLogins(for: query)
        XCTAssertEqual(logins.map(\.uuid), [mailID])
        XCTAssertEqual(Set(fixture.prompts.accessRequests.first?.titles ?? []), ["Mail", "Mail (old)"])

        let candidates = try await fixture.storedCandidates()
        let mailAccess = try XCTUnwrap(candidates.first { $0.id == mailID }?.access)
        XCTAssertEqual(Set(mailAccess.allowedHosts), ["mail.example.com", "auth.example.com"])
        let oldAccess = try XCTUnwrap(candidates.first { $0.id == oldID }?.access)
        XCTAssertEqual(Set(oldAccess.deniedHosts), ["mail.example.com", "auth.example.com"])
        XCTAssertEqual(fixture.vault?.entries.first { $0.id == mailID }?.history.count, 0)

        let again = await fixture.controller.browserLogins(for: query)
        XCTAssertEqual(again.map(\.uuid), [mailID])
        XCTAssertEqual(fixture.prompts.accessRequests.count, 1, "remembered answers aren't asked again")
    }

    func testDeniedAccessReturnsNothing() async throws {
        let fixture = try await makeFixture([Self.mail])
        fixture.prompts.accessAnswer = { _ in BrowserAccessAnswer(allowed: [], remember: true) }

        let denied = await fixture.controller.browserLogins(for: Self.mailQuery)
        XCTAssertTrue(denied.isEmpty)
        let access = try await fixture.storedCandidates().first?.access
        XCTAssertEqual(access?.deniedHosts, ["mail.example.com"])

        let again = await fixture.controller.browserLogins(for: Self.mailQuery)
        XCTAssertTrue(again.isEmpty)
        XCTAssertEqual(fixture.prompts.accessRequests.count, 1)
    }

    func testAlwaysAllowAccessAndExpiredEntries() async throws {
        let expired = VaultEntryForm(title: "Expired", username: "e", password: "p", url: "https://mail.example.com", expiresAt: Date().addingTimeInterval(-3600))
        let fixture = try await makeFixture([Self.mail, expired])
        fixture.controller.alwaysAllowAccess = true
        XCTAssertTrue(fixture.settings.browserAlwaysAllowAccess)

        let current = await fixture.controller.browserLogins(for: Self.mailQuery)
        XCTAssertEqual(current.map(\.name), ["Mail"], "expired logins stay out by default")
        XCTAssertTrue(fixture.prompts.accessRequests.isEmpty)

        fixture.controller.allowExpired = true
        XCTAssertTrue(fixture.settings.browserAllowExpired)
        let all = await fixture.controller.browserLogins(for: Self.mailQuery)
        XCTAssertEqual(Set(all.map(\.name)), ["Mail", "Expired"])
        XCTAssertEqual(all.first { $0.name == "Expired" }?.isExpired, true)
        XCTAssertEqual(all.first { $0.name == "Mail" }?.isExpired, false)
    }

    func testTOTP() async throws {
        let fixture = try await makeFixture([
            VaultEntryForm(title: "Bank", username: "u", password: "p", url: "https://bank.example", otp: VaultOTPForm(secret: "JBSWY3DPEHPK3PXP"))
        ])
        fixture.controller.alwaysAllowAccess = true
        let bankID = try fixture.id("Bank")

        let logins = await fixture.controller.browserLogins(for: BrowserLoginQuery(siteURL: "https://bank.example/", formURL: "", httpAuth: false))
        let loginCode = try XCTUnwrap(logins.first?.totp)
        XCTAssertEqual(loginCode.count, 6)

        let totp = await fixture.controller.browserTOTP(forEntry: bankID)
        let code = try XCTUnwrap(totp)
        XCTAssertEqual(code.count, 6)
        XCTAssertTrue(code.allSatisfy(\.isNumber))
        let unknown = await fixture.controller.browserTOTP(forEntry: UUID())
        XCTAssertNil(unknown)

        try await fixture.model.deleteEntry(id: bankID)
        let trashed = await fixture.controller.browserTOTP(forEntry: bankID)
        XCTAssertNil(trashed, "entries in the recycle bin have no code")
    }

    func testHOTPCodeIsUsedOnlyWhenTheBrowserAsksForIt() async throws {
        let fixture = try await makeFixture([
            VaultEntryForm(title: "Bank", username: "u", password: "p", url: "https://bank.example", otp: VaultOTPForm(
                secret: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ",
                kind: .hotp,
                counter: 5
            ))
        ])
        fixture.controller.alwaysAllowAccess = true
        let bankID = try fixture.id("Bank")

        let logins = await fixture.controller.browserLogins(for: BrowserLoginQuery(siteURL: "https://bank.example/", formURL: "", httpAuth: false))
        XCTAssertEqual(logins.map(\.name), ["Bank"])
        XCTAssertNil(logins.first?.totp, "listing logins doesn't hand out HOTP codes")
        let listed = try await fixture.storedEntry { $0.title == "Bank" }
        XCTAssertEqual(listed.otp?.counter, 5)

        let first = await fixture.controller.browserTOTP(forEntry: bankID)
        let second = await fixture.controller.browserTOTP(forEntry: bankID)
        XCTAssertEqual(first, "254676", "RFC 4226 code for counter 5")
        XCTAssertEqual(second, "287922", "the next request gets the next code")
        let stored = try await fixture.storedEntry { $0.title == "Bank" }
        XCTAssertEqual(stored.otp?.counter, 7)

        async let third = fixture.controller.browserTOTP(forEntry: bankID)
        async let fourth = fixture.controller.browserTOTP(forEntry: bankID)
        let together = await [third, fourth]
        XCTAssertEqual(Set(together.compactMap { $0 }), ["162583", "399871"], "requests at the same time get different codes")
    }

    // MARK: - Saving

    func testSaveNewLoginGoesToBrowserGroup() async throws {
        let fixture = try await makeFixture()
        let saved = await fixture.controller.saveBrowserLogin(BrowserSaveRequest(
            siteURL: "https://new.example.com/login", formURL: "https://auth.example.com/post",
            login: "neo", password: "red-pill", entryID: nil, groupID: nil
        ))
        XCTAssertTrue(saved)
        XCTAssertTrue(fixture.prompts.updateRequests.isEmpty)

        let entry = try XCTUnwrap(fixture.vault?.entries.first { $0.title == "new.example.com" }, "the model shows the saved entry")
        XCTAssertTrue(entry.groupPath.hasSuffix("KeePassXC-Browser Passwords"))
        XCTAssertEqual(entry.username, "neo")
        XCTAssertEqual(entry.password, "red-pill")

        let (reopened, vault) = try await fixture.reopen()
        XCTAssertEqual(vault.entries.first { $0.id == entry.id }?.url?.absoluteString, "https://new.example.com/login")
        let access = await reopened.browserCandidates().first { $0.id == entry.id }?.access
        XCTAssertEqual(access?.allowedHosts, ["new.example.com", "auth.example.com"])

        let logins = await fixture.controller.browserLogins(for: BrowserLoginQuery(siteURL: "https://new.example.com/login", formURL: "https://auth.example.com/post", httpAuth: false))
        XCTAssertEqual(logins.map(\.uuid), [entry.id])
        XCTAssertTrue(fixture.prompts.accessRequests.isEmpty, "a login saved from the browser fills without asking")
    }

    func testUpdateExistingLoginAsksFirst() async throws {
        let fixture = try await makeFixture([Self.mail])
        let mailID = try fixture.id("Mail")
        func request(_ login: String, _ password: String, id: UUID? = mailID) -> BrowserSaveRequest {
            BrowserSaveRequest(siteURL: "https://mail.example.com/login", formURL: "", login: login, password: password, entryID: id, groupID: nil)
        }

        fixture.prompts.updateAnswer = false
        let declined = await fixture.controller.saveBrowserLogin(request("anna", "new-secret"))
        XCTAssertFalse(declined)
        let declinedRequest = try XCTUnwrap(fixture.prompts.updateRequests.first)
        XCTAssertEqual(declinedRequest.site, "mail.example.com")
        XCTAssertEqual(declinedRequest.title, "Mail")
        XCTAssertNil(declinedRequest.newUsername)
        XCTAssertTrue(declinedRequest.changesPassword)
        let kept = try await fixture.storedEntry { $0.id == mailID }
        XCTAssertEqual(kept.password, "secret")

        fixture.prompts.updateAnswer = true
        let accepted = await fixture.controller.saveBrowserLogin(request("anna", "new-secret"))
        XCTAssertTrue(accepted)
        let updated = try await fixture.storedEntry { $0.id == mailID }
        XCTAssertEqual(updated.password, "new-secret")
        XCTAssertEqual(updated.history.count, 1, "the old password goes to history")
        XCTAssertEqual(fixture.vault?.entries.first { $0.id == mailID }?.password, "new-secret")

        let unchanged = await fixture.controller.saveBrowserLogin(request("anna", "new-secret"))
        XCTAssertTrue(unchanged)
        XCTAssertEqual(fixture.prompts.updateRequests.count, 2, "nothing changed, nothing asked")

        _ = await fixture.controller.saveBrowserLogin(request("bob", "new-secret"))
        XCTAssertEqual(fixture.prompts.updateRequests.last?.newUsername, "bob")
        XCTAssertEqual(fixture.prompts.updateRequests.last?.changesPassword, false)

        fixture.controller.alwaysAllowUpdate = true
        XCTAssertTrue(fixture.settings.browserAlwaysAllowUpdate)
        let silent = await fixture.controller.saveBrowserLogin(request("bob", "third"))
        XCTAssertTrue(silent)
        XCTAssertEqual(fixture.prompts.updateRequests.count, 3)
        let final = try await fixture.storedEntry { $0.id == mailID }
        XCTAssertEqual(final.username, "bob")
        XCTAssertEqual(final.password, "third")

        let missing = await fixture.controller.saveBrowserLogin(request("carol", "pw", id: UUID()))
        XCTAssertTrue(missing)
        XCTAssertTrue(fixture.vault?.entries.contains { $0.username == "carol" && $0.groupPath.hasSuffix("KeePassXC-Browser Passwords") } ?? false,
                      "an update for a missing entry saves a new one")
    }

    func testCreateGroupAndSaveIntoIt() async throws {
        let fixture = try await makeFixture()
        let controller = fixture.controller

        fixture.prompts.groupAnswer = false
        let declined = await controller.createBrowserGroup(path: "Web / Shops")
        XCTAssertNil(declined)
        XCTAssertEqual(fixture.prompts.groupRequests, ["Web / Shops"])

        fixture.prompts.groupAnswer = true
        let group = await controller.createBrowserGroup(path: "Web/Shops")
        let created = try XCTUnwrap(group)
        XCTAssertEqual(created.title, "Shops")
        let tree = await controller.browserGroups()
        XCTAssertEqual(tree?.children.first { $0.title == "Web" }?.children.map(\.id), [created.id])
        XCTAssertTrue(fixture.vault?.groups.contains { $0.id == created.id } ?? false)

        let existing = await controller.createBrowserGroup(path: "Web/Shops")
        XCTAssertEqual(existing?.id, created.id)
        XCTAssertEqual(fixture.prompts.groupRequests.count, 2, "existing groups are returned without asking")
        let empty = await controller.createBrowserGroup(path: " / ")
        XCTAssertNil(empty)
        XCTAssertEqual(fixture.prompts.groupRequests.count, 2)

        let saved = await controller.saveBrowserLogin(BrowserSaveRequest(
            siteURL: "https://shop.example", formURL: "", login: "u", password: "p", entryID: nil, groupID: created.id
        ))
        XCTAssertTrue(saved)
        let entry = try await fixture.storedEntry { $0.title == "shop.example" }
        XCTAssertTrue(entry.groupPath.hasSuffix("Web.Shops"))
    }

    func testGeneratePasswordComesFromPrompt() async throws {
        let fixture = try await makeFixture()
        let password = await fixture.controller.generateBrowserPassword()
        XCTAssertEqual(password, "Gen3rated!")
        fixture.prompts.generatedPassword = nil
        let cancelled = await fixture.controller.generateBrowserPassword()
        XCTAssertNil(cancelled)
    }

    // MARK: - Locking

    func testLockedVaultAnswersNothing() async throws {
        let fixture = try await makeFixture([Self.mail])
        let controller = fixture.controller
        controller.alwaysAllowAccess = true
        let mailID = try fixture.id("Mail")
        _ = await controller.associateBrowser(identificationKey: "a2V5")
        await fixture.lock()
        XCTAssertFalse(controller.isVaultUnlocked)
        await waitUntil("locking forgets the associations") { controller.associations.isEmpty }

        let hash = await controller.browserDatabaseHash()
        XCTAssertNil(hash)
        let key = await controller.browserAssociationKey(for: "chrome-mac")
        XCTAssertNil(key)
        let associated = await controller.associateBrowser(identificationKey: "a2V5")
        XCTAssertNil(associated)
        let logins = await controller.browserLogins(for: Self.mailQuery)
        XCTAssertTrue(logins.isEmpty)
        let totp = await controller.browserTOTP(forEntry: mailID)
        XCTAssertNil(totp)
        let groups = await controller.browserGroups()
        XCTAssertNil(groups)
        let group = await controller.createBrowserGroup(path: "Web")
        XCTAssertNil(group)
        let saved = await controller.saveBrowserLogin(BrowserSaveRequest(siteURL: "https://a.example", formURL: "", login: "a", password: "b", entryID: nil, groupID: nil))
        XCTAssertFalse(saved)
        XCTAssertEqual(fixture.prompts.connectionRequests.count, 1)
        XCTAssertTrue(fixture.prompts.groupRequests.isEmpty)
    }

    func testLockWhileAskingForAccessReturnsNothing() async throws {
        let fixture = try await makeFixture([Self.mail])
        let model = fixture.model
        fixture.prompts.accessAnswer = { entries in
            model.lockVault(reason: .quickAccess)
            return BrowserAccessAnswer(allowed: Set(entries.map(\.id)), remember: true)
        }

        let logins = await fixture.controller.browserLogins(for: Self.mailQuery)
        XCTAssertTrue(logins.isEmpty)
        await model.finishPendingLock()
        await waitUntil("the lock cancels open prompts") { fixture.prompts.cancelCount > 0 }
        let access = try await fixture.storedCandidates().first?.access
        XCTAssertNil(access, "an answer given after locking isn't saved")
    }

    func testLockAndUnlockAreBroadcastToBrowsers() async throws {
        let fixture = try await makeFixture()
        let controller = fixture.controller
        _ = await controller.associateBrowser(identificationKey: "a2V5")

        controller.setEnabled(true)
        XCTAssertEqual(controller.serverState, .running)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertTrue(fixture.settings.browserIntegrationEnabled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.socketPath))

        let browser = try XCTUnwrap(SocketFrameReader(path: fixture.socketPath))
        defer { browser.close() }
        try browser.send(["action": "change-public-keys"])
        let accepted = await browser.next()
        XCTAssertEqual(accepted?["action"] as? String, "change-public-keys", "the server answers once it has accepted the connection")

        await fixture.lock()
        let locked = await browser.next()
        XCTAssertEqual(locked?["action"] as? String, "database-locked")
        XCTAssertTrue(controller.associations.isEmpty)
        await waitUntil("prompts are cancelled on lock") { fixture.prompts.cancelCount > 0 }

        await fixture.model.unlock(masterPassword: fixture.password)
        let unlocked = await browser.next()
        XCTAssertEqual(unlocked?["action"] as? String, "database-unlocked")
        XCTAssertEqual(controller.associations.map(\.id), ["chrome-mac"], "associations are loaded before the browser hears about the unlock")

        let other = BrowserIntegrationController(settings: fixture.settings, prompts: FakePrompts(), socketPath: fixture.socketPath, manifestDirectory: fixture.manifestDirectory, proxyURL: nil)
        other.setEnabled(true)
        XCTAssertEqual(other.serverState, .failed(L("Another KeeMac is already serving the browser extension.")))
        other.shutdown()
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.socketPath), "the failed one leaves the running socket alone")

        let cancelsBefore = fixture.prompts.cancelCount
        controller.setEnabled(false)
        XCTAssertEqual(controller.serverState, .off)
        XCTAssertFalse(fixture.settings.browserIntegrationEnabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.socketPath))
        XCTAssertGreaterThan(fixture.prompts.cancelCount, cancelsBefore)
        let closed = await browser.next()
        XCTAssertNil(closed, "turning it off disconnects browsers")
    }

    func testLockForBrowserAndUnlockWindow() async throws {
        let fixture = try await makeFixture()
        let controller = fixture.controller

        let shown = expectation(forNotification: AppCommand.showMainWindow, object: nil)
        controller.showUnlockForBrowser()
        await fulfillment(of: [shown], timeout: 5)
        XCTAssertEqual(fixture.prompts.unlockRequests, 0, "an unlocked database brings the main window instead")

        controller.lockForBrowser()
        XCTAssertFalse(fixture.model.loadState.isUnlocked)
        await fixture.model.finishPendingLock()

        fixture.prompts.holdsUnlock = true
        controller.showUnlockForBrowser()
        controller.showUnlockForBrowser()
        await waitUntil("the unlock window opens") { fixture.prompts.unlockRequests == 1 }
        await Task.yield()
        XCTAssertEqual(fixture.prompts.unlockRequests, 1, "one unlock window at a time")

        fixture.prompts.holdsUnlock = false
        fixture.prompts.releaseUnlock()
        await waitUntil("a new window can open after the first closed") {
            controller.showUnlockForBrowser()
            return fixture.prompts.unlockRequests >= 2
        }
    }

    // MARK: - Native messaging hosts through the controller

    func testConfigureStartsServerAndRepairsMovedManifests() async throws {
        let fixture = try await makeFixture(configure: false)
        let proxy = fixture.directory.appendingPathComponent("New/keemac-proxy")
        try FileManager.default.createDirectory(at: proxy.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: proxy.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        let oldProxy = fixture.directory.appendingPathComponent("Old/keemac-proxy")
        try NativeMessagingHosts.install(for: .chrome, proxyURL: oldProxy, in: fixture.manifestDirectory)
        try FileManager.default.createDirectory(at: fixture.manifestDirectory.appendingPathComponent("BraveSoftware/Brave-Browser"), withIntermediateDirectories: true)

        fixture.settings.browserIntegrationEnabled = true
        let controller = BrowserIntegrationController(
            settings: fixture.settings, prompts: fixture.prompts, socketPath: fixture.socketPath,
            manifestDirectory: fixture.manifestDirectory, proxyURL: proxy
        )
        defer { controller.shutdown() }
        controller.configure(viewModel: fixture.model)

        XCTAssertEqual(controller.serverState, .running)
        XCTAssertTrue(controller.isProxyAvailable)
        XCTAssertEqual(controller.hostStates[.chrome], .installed, "the manifest now points at the moved proxy")
        XCTAssertEqual(controller.hostStates[.brave], .notInstalled, "only outdated manifests are rewritten")
        XCTAssertEqual(controller.hostStates[.firefox], .browserNotFound)
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: NativeMessagingHosts.manifestURL(for: .chrome, in: fixture.manifestDirectory))) as? [String: Any]
        XCTAssertEqual(manifest?["path"] as? String, proxy.path)
        let hash = await controller.browserDatabaseHash()
        XCTAssertNotNil(hash)
    }

    func testSetHostInstallsAndRemovesManifests() async throws {
        let fixture = try await makeFixture()
        try FileManager.default.createDirectory(at: fixture.manifestDirectory.appendingPathComponent("Mozilla"), withIntermediateDirectories: true)
        let controller = fixture.controller
        controller.refreshHostStates()
        XCTAssertEqual(controller.hostStates[.firefox], .notInstalled)
        XCTAssertFalse(controller.isProxyAvailable)

        controller.setHost(.firefox, installed: true)
        XCTAssertEqual(controller.hostError, L("keemac-proxy is missing next to the KeeMac executable."))
        XCTAssertEqual(controller.hostStates[.firefox], .notInstalled)

        let proxy = fixture.directory.appendingPathComponent("keemac-proxy")
        FileManager.default.createFile(atPath: proxy.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        let withProxy = BrowserIntegrationController(
            settings: fixture.settings, prompts: FakePrompts(), socketPath: fixture.socketPath,
            manifestDirectory: fixture.manifestDirectory, proxyURL: proxy
        )
        withProxy.setHost(.firefox, installed: true)
        XCTAssertNil(withProxy.hostError)
        XCTAssertEqual(withProxy.hostStates[.firefox], .installed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: NativeMessagingHosts.manifestURL(for: .firefox, in: fixture.manifestDirectory).path))

        withProxy.setHost(.firefox, installed: false)
        XCTAssertEqual(withProxy.hostStates[.firefox], .notInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: NativeMessagingHosts.manifestURL(for: .firefox, in: fixture.manifestDirectory).path))
    }
}
