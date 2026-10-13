@testable import Data
import Domain
import Foundation
import KeePassKit
@testable import UI
import XCTest

final class OTPKindsGeneratorTests: XCTestCase {
    private static let rfcSeed = Data("12345678901234567890".utf8)

    func testHOTPMatchesRFC4226Vectors() throws {
        let expected = ["755224", "287082", "359152", "969429", "338314", "254676", "287922", "162583", "399871", "520489"]
        for (counter, code) in expected.enumerated() {
            XCTAssertEqual(OTPCodeGenerator.code(secret: Self.rfcSeed, counter: UInt64(counter), digits: 6, algorithm: .sha1), code, "counter \(counter)")
        }

        let config = VaultOTPConfiguration(secret: Self.rfcSeed, digits: 6, period: 30, timeBase: 0, algorithm: .sha1, kind: .hotp, counter: 5)
        let state = try XCTUnwrap(OTPCodeGenerator.makeCodeState(from: config, now: Date(timeIntervalSince1970: 1_000_000)))
        XCTAssertEqual(state.code, "254676", "HOTP ignores the clock")
        XCTAssertEqual(state.counter, 5)
        XCTAssertTrue(state.isCounterBased)
        XCTAssertEqual(state.remainingSeconds, 0)
    }

    func testSteamCodesUseFiveSteamCharacters() throws {
        let config = VaultOTPConfiguration(secret: Self.rfcSeed, digits: 5, period: 30, timeBase: 0, algorithm: .sha1, kind: .steam)
        let state = try XCTUnwrap(OTPCodeGenerator.makeCodeState(from: config, now: Date(timeIntervalSince1970: 59)))
        XCTAssertEqual(state.code.count, 5)
        XCTAssertTrue(state.code.allSatisfy { "23456789BCDFGHJKMNPQRTVWXY".contains($0) })
        XCTAssertEqual(state.remainingSeconds, 1)
        XCTAssertNil(state.counter)
        XCTAssertEqual(OTPCodeGenerator.steamCode(secret: Self.rfcSeed, counter: 1), state.code)
    }

    /// The same settings must give the codes KeePassKit (MacPass) computes.
    func testCodesMatchKeePassKit() throws {
        let tree = KPKTree(templateContents: ())
        let group = try XCTUnwrap(tree.root)

        let hotp = tree.createEntry(group)
        hotp.add(to: group)
        hotp.addCustomAttribute(KPKAttribute(key: kKPKAttributeKeyHmacOTPSecret, value: "12345678901234567890", isProtected: true))
        hotp.addCustomAttribute(KPKAttribute(key: kKPKAttributeKeyHmacOTPCounter, value: "7", isProtected: false))
        XCTAssertTrue(hotp.hasHmacOTP)
        XCTAssertEqual(hotp.hmacOTP, OTPCodeGenerator.code(secret: Self.rfcSeed, counter: 7, digits: 6, algorithm: .sha1))

        let steam = KPKSteamOTPGenerator()
        steam.key = Self.rfcSeed
        let config = VaultOTPConfiguration(secret: Self.rfcSeed, digits: 5, period: 30, timeBase: 0, algorithm: .sha1, kind: .steam)
        for time in [59.0, 1_111_111_109, 1_234_567_890, 2_000_000_000] {
            steam.time = time
            XCTAssertEqual(OTPCodeGenerator.makeCodeState(from: config, now: Date(timeIntervalSince1970: time))?.code, steam.string, "at \(time)")
        }
    }
}

final class VaultOTPURITests: XCTestCase {
    func testParsesHOTPAndSteam() throws {
        let hotp = try XCTUnwrap(VaultOTPURI.parse("otpauth://hotp/Bank:anna?secret=JBSWY3DPEHPK3PXP&counter=42&digits=8&algorithm=SHA256"))
        XCTAssertEqual(hotp.kind, .hotp)
        XCTAssertEqual(hotp.counter, 42)
        XCTAssertEqual(hotp.digits, 8)
        XCTAssertEqual(hotp.algorithm, .sha256)
        XCTAssertEqual(VaultOTPURI.parse("otpauth://hotp/Bank?secret=AAAA&counter=-3")?.counter, 0)

        for uri in [
            "otpauth://totp/Steam:anna?secret=JBSWY3DPEHPK3PXP&issuer=Steam&encoder=steam",
            "otpauth://steam/Steam:anna?secret=JBSWY3DPEHPK3PXP"
        ] {
            let steam = try XCTUnwrap(VaultOTPURI.parse(uri))
            XCTAssertEqual(steam.kind, .steam, uri)
            XCTAssertEqual(steam.digits, 5)
            XCTAssertEqual(steam.period, 30)
        }
        XCTAssertNil(VaultOTPURI.parse("JBSWY3DPEHPK3PXP"))
    }

    func testTOTPAfterSteamGetsUsualDefaults() throws {
        let steam = VaultOTPForm(secret: "AAAA", digits: 5, period: 30, kind: .steam)
        let totp = try XCTUnwrap(VaultOTPURI.parse("otpauth://totp/x?secret=BBBB", base: steam))
        XCTAssertEqual(totp.kind, .totp)
        XCTAssertEqual(totp.digits, 6)
        XCTAssertEqual(totp.period, 30)
    }

    func testMadeURIsReadBack() throws {
        for kind in VaultOTPKind.allCases {
            let uri = VaultOTPURI.make(kind: kind, secret: "JBSWY3DPEHPK3PXP", label: "Bank: anna", digits: 7, period: 45, algorithm: .sha512, counter: 9)
            let form = try XCTUnwrap(VaultOTPURI.parse(uri), uri)
            XCTAssertEqual(form.kind, kind)
            XCTAssertEqual(form.secret, "JBSWY3DPEHPK3PXP")
            switch kind {
            case .totp:
                XCTAssertEqual([form.digits, form.period], [7, 45])
                XCTAssertEqual(form.algorithm, .sha512)
            case .hotp:
                XCTAssertEqual([form.digits, form.counter], [7, 9])
                XCTAssertEqual(form.algorithm, .sha512)
            case .steam:
                XCTAssertEqual([form.digits, form.period], [5, 30])
            }
        }
    }

    func testInputParserAndValidation() {
        let parsed = OTPInputParser.apply("otpauth://hotp/x?secret=AAAA&counter=3", to: VaultOTPForm(secret: "", storageStyle: .native))
        XCTAssertEqual(parsed?.kind, .hotp)
        XCTAssertEqual(parsed?.counter, 3)
        XCTAssertEqual(parsed?.storageStyle, .native, "the chosen storage stays")

        let raw = OTPInputParser.apply("CCCC", to: VaultOTPForm(secret: "", kind: .hotp, counter: 4))
        XCTAssertEqual(raw?.kind, .hotp, "a bare secret keeps the chosen kind")
        XCTAssertEqual(raw?.counter, 4)

        var form = VaultEntryForm(title: "Steam", otp: VaultOTPForm(secret: "AAAA", digits: 5, kind: .steam))
        XCTAssertNil(EntryFormValidation.validate(form), "Steam's five characters are fine")
        form.otp = VaultOTPForm(secret: "AAAA", period: 0, kind: .hotp)
        XCTAssertNil(EntryFormValidation.validate(form), "HOTP has no period")
        form.otp = VaultOTPForm(secret: "AAAA", kind: .hotp, counter: -1)
        XCTAssertNotNil(EntryFormValidation.validate(form))
    }
}

final class OTPKindsLoaderTests: XCTestCase {
    private var directory: URL!
    private var vaultURL: URL!
    private let password = "otp-test"

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        vaultURL = directory.appendingPathComponent("OTP.kdbx")
        let fastKDF = VaultDatabaseSettings(kdf: .argon2id, argonIterations: 1, argonMemoryMiB: 8, argonParallelism: 1)
        _ = try await KeePassKitVaultLoader().createVault(options: VaultCreationOptions(
            fileURL: vaultURL,
            name: "OTP",
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

    private func entry(_ title: String, in vault: LoadedVault) throws -> VaultEntry {
        try XCTUnwrap(vault.entries.first { $0.title == title })
    }

    /// The saved entry's own attributes, read with KeePassKit as another client would.
    private func storedAttributes(_ title: String) throws -> [String: String] {
        let key = KPKCompositeKey(keys: [try XCTUnwrap(KPKPasswordKey(password: password))])
        let tree = try KPKTree(data: Data(contentsOf: vaultURL), key: key)
        let entry = try XCTUnwrap(tree.allEntries.first { !$0.isHistory && $0.title == title })
        var attributes: [String: String] = [:]
        for attribute in entry.customAttributes ?? [] {
            attributes[attribute.key] = attribute.value
        }
        return attributes
    }

    /// Adds an entry with raw OTP attributes, the way other clients write them.
    private func addRawEntry(_ title: String, attributes: [String: String]) throws {
        let key = KPKCompositeKey(keys: [try XCTUnwrap(KPKPasswordKey(password: password))])
        let tree = try KPKTree(data: Data(contentsOf: vaultURL), key: key)
        let group = try XCTUnwrap(tree.root)
        let entry = tree.createEntry(group)
        entry.add(to: group)
        entry.title = title
        for (name, value) in attributes {
            entry.addCustomAttribute(KPKAttribute(key: name, value: value, isProtected: false))
        }
        try tree.encrypt(with: key, format: .kdbx).write(to: vaultURL, options: .atomic)
    }

    func testHOTPIsStoredInKeePassFields() async throws {
        let (loader, _) = try await open()
        _ = try await loader.createEntry(inGroupPath: nil, form: VaultEntryForm(
            title: "Bank",
            otp: VaultOTPForm(secret: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", kind: .hotp, counter: 5)
        ))

        let stored = try storedAttributes("Bank")
        XCTAssertEqual(stored[kKPKAttributeKeyHmacOTPSecretBase32], "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")
        XCTAssertEqual(stored[kKPKAttributeKeyHmacOTPCounter], "5")
        XCTAssertNil(stored[kKPKAttributeKeyOTPOAuthURL], "6 digits and SHA-1 need no URI")

        let reloaded = try await open().1
        let bank = try entry("Bank", in: reloaded)
        XCTAssertEqual(bank.otp?.kind, .hotp)
        XCTAssertEqual(bank.otp?.counter, 5)
        XCTAssertEqual(bank.otpStorageStyle, .native)
        XCTAssertEqual(OTPCodeGenerator.makeCodeState(from: try XCTUnwrap(bank.otp), now: Date())?.code, "254676")
    }

    func testAdvancingHOTPSkipsHistoryAndUndo() async throws {
        let (loader, _) = try await open()
        _ = try await loader.createEntry(inGroupPath: nil, form: VaultEntryForm(
            title: "Bank",
            otp: VaultOTPForm(secret: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", digits: 8, kind: .hotp, counter: 1)
        ))
        let created = try entry("Bank", in: try await open().1)
        let undoBefore = await loader.undoState()

        _ = try await loader.advanceHOTPCounter(id: created.id)
        let advanced = try await loader.advanceHOTPCounter(id: created.id)
        let bank = try entry("Bank", in: advanced)
        XCTAssertEqual(bank.otp?.counter, 3)
        XCTAssertEqual(bank.otp?.digits, 8)
        XCTAssertEqual(bank.history.count, created.history.count, "no history version for a counter")
        let undoAfter = await loader.undoState()
        XCTAssertEqual(undoAfter, undoBefore, "no undo step for a counter")

        let stored = try storedAttributes("Bank")
        XCTAssertEqual(stored[kKPKAttributeKeyHmacOTPCounter], "3")
        XCTAssertTrue(try XCTUnwrap(stored[kKPKAttributeKeyOTPOAuthURL]).contains("counter=3"), "the URI follows the counter")
        let reopened = try entry("Bank", in: try await open().1)
        XCTAssertEqual(reopened.otp?.counter, 3)
    }

    func testAdvancingTOTPFails() async throws {
        let (loader, _) = try await open()
        let vault = try await loader.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Mail", otp: VaultOTPForm(secret: "JBSWY3DPEHPK3PXP")))
        do {
            _ = try await loader.advanceHOTPCounter(id: try entry("Mail", in: vault).id)
            XCTFail("TOTP has no counter")
        } catch {}
    }

    func testUndoDoesNotTakeTheCounterBack() async throws {
        let (loader, _) = try await open()
        var vault = try await loader.createEntry(inGroupPath: nil, form: VaultEntryForm(
            title: "Bank",
            otp: VaultOTPForm(secret: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", kind: .hotp)
        ))
        let id = try entry("Bank", in: vault).id
        var form = VaultEntryForm(entry: try entry("Bank", in: vault))
        form.title = "Bank Renamed"
        _ = try await loader.updateEntry(id: id, form: form)
        _ = try await loader.advanceHOTPCounter(id: id)
        _ = try await loader.advanceHOTPCounter(id: id)

        vault = try await loader.undo()
        let bank = try XCTUnwrap(vault.entries.first { $0.id == id })
        XCTAssertEqual(bank.title, "Bank", "the rename is undone")
        XCTAssertEqual(bank.otp?.counter, 2, "the counter stays")
    }

    func testMergeKeepsTheHighestCounter() async throws {
        let (setup, _) = try await open()
        let created = try await setup.createEntry(inGroupPath: nil, form: VaultEntryForm(
            title: "Bank",
            otp: VaultOTPForm(secret: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", kind: .hotp)
        ))
        let id = try entry("Bank", in: created).id

        let (mac, macVault) = try await open()
        let (phone, _) = try await open()
        for _ in 0..<3 {
            _ = try await phone.advanceHOTPCounter(id: id)
        }

        // The Mac's later edit wins the merge, but its older counter mustn't.
        try await Task.sleep(for: .milliseconds(1100))
        var form = VaultEntryForm(entry: try entry("Bank", in: macVault))
        form.username = "anna"
        let merged = try await mac.updateEntry(id: id, form: form)
        let bank = try entry("Bank", in: merged)
        XCTAssertEqual(bank.username, "anna")
        XCTAssertEqual(bank.otp?.counter, 3)
        let reopened = try entry("Bank", in: try await open().1)
        XCTAssertEqual(reopened.otp?.counter, 3)
    }

    func testSteamIsStoredLikeKeePassXCAndKeeOtp() async throws {
        let (loader, _) = try await open()
        _ = try await loader.createEntry(inGroupPath: nil, form: VaultEntryForm(
            title: "Steam URI",
            otp: VaultOTPForm(secret: "JBSWY3DPEHPK3PXP", digits: 5, storageStyle: .otpAuth, kind: .steam)
        ))
        _ = try await loader.createEntry(inGroupPath: nil, form: VaultEntryForm(
            title: "Steam Native",
            otp: VaultOTPForm(secret: "JBSWY3DPEHPK3PXP", digits: 5, storageStyle: .native, kind: .steam)
        ))

        XCTAssertTrue(try XCTUnwrap(storedAttributes("Steam URI")[kKPKAttributeKeyOTPOAuthURL]).contains("encoder=steam"))
        let native = try storedAttributes("Steam Native")
        XCTAssertEqual(native[kKPKAttributeKeyTimeOTPSeed], "JBSWY3DPEHPK3PXP")
        XCTAssertEqual(native[kKPKAttributeKeyTimeOTPSettings], "30;S")

        let reloaded = try await open().1
        for title in ["Steam URI", "Steam Native"] {
            let steam = try entry(title, in: reloaded)
            XCTAssertEqual(steam.otp?.kind, .steam, title)
            XCTAssertEqual(steam.otp?.digits, 5, title)
            XCTAssertEqual(OTPCodeGenerator.makeCodeState(from: try XCTUnwrap(steam.otp), now: Date())?.code.count, 5)
        }
    }

    func testReadsOtherClientsFormats() async throws {
        try addRawEntry("KeePassXC Steam", attributes: [
            kKPKAttributeKeyOTPOAuthURL: "otpauth://totp/Steam:anna?secret=JBSWY3DPEHPK3PXP&period=30&digits=5&issuer=Steam&encoder=steam"
        ])
        try addRawEntry("KeeOtp Steam", attributes: [
            kKPKAttributeKeyTimeOTPSeed: "JBSWY3DPEHPK3PXP",
            kKPKAttributeKeyTimeOTPSettings: "30;S"
        ])
        try addRawEntry("Legacy TOTP", attributes: [
            kKPKAttributeKeyTimeOTPSeed: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ",
            kKPKAttributeKeyTimeOTPSettings: "30;8"
        ])
        try addRawEntry("KeePass HOTP", attributes: [
            kKPKAttributeKeyHmacOTPSecret: "12345678901234567890",
            kKPKAttributeKeyHmacOTPCounter: "9"
        ])

        let vault = try await open().1
        XCTAssertEqual(try entry("KeePassXC Steam", in: vault).otp?.kind, .steam)
        XCTAssertEqual(try entry("KeeOtp Steam", in: vault).otp?.kind, .steam)

        let legacy = try XCTUnwrap(try entry("Legacy TOTP", in: vault).otp)
        XCTAssertEqual(legacy.kind, .totp)
        XCTAssertEqual(legacy.timeBase, 0, "TOTP Seed is the secret, not a time base")
        XCTAssertEqual(OTPCodeGenerator.makeCodeState(from: legacy, now: Date(timeIntervalSince1970: 59))?.code, "94287082")

        let hotp = try XCTUnwrap(try entry("KeePass HOTP", in: vault).otp)
        XCTAssertEqual(hotp.kind, .hotp)
        XCTAssertEqual(OTPCodeGenerator.makeCodeState(from: hotp, now: Date())?.code, "520489")
    }

    func testImportedHOTPURIBecomesNativeAndExportsWithCounter() async throws {
        let (loader, _) = try await open()
        let file = VaultImportFile(format: .chrome, items: [
            VaultImportItem(title: "Bank", username: "anna", otp: "otpauth://hotp/Bank?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&counter=4")
        ])
        _ = try await loader.importEntries(file, options: VaultImportOptions(destination: .newGroup(title: "Imported"), keepsFolders: false, skipsDuplicates: false))

        let stored = try storedAttributes("Bank")
        XCTAssertEqual(stored[kKPKAttributeKeyHmacOTPCounter], "4")
        XCTAssertNil(stored[kKPKAttributeKeyOTPOAuthURL])

        let export = try await loader.exportDatabase(VaultExportOptions(format: .csv, groupPath: nil, includesTrash: false, includesHistory: false, includesAttachments: false))
        let csv = try XCTUnwrap(String(data: export.data, encoding: .utf8))
        XCTAssertTrue(csv.contains("otpauth://hotp/Bank?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"), csv)
        XCTAssertTrue(csv.contains("counter=4"))
    }
}
