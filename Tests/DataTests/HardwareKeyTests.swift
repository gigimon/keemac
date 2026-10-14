import CryptoKit
@testable import Data
import Domain
import Foundation
import KeePassKit
@testable import UI
import XCTest

final class HardwareKeyTests: XCTestCase {
    private var directory: URL!
    private var vaultURL: URL!
    private let password = "hardware"
    private let secret = Data((1...20).map { UInt8($0) })
    private var yubiKey: SoftwareHardwareKey!
    private static let fastKDF = VaultDatabaseSettings(kdf: .argon2id, argonIterations: 1, argonMemoryMiB: 8, argonParallelism: 1)

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        vaultURL = directory.appendingPathComponent("Hardware.kdbx")
        yubiKey = SoftwareHardwareKey(secret: secret)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func createVault(password: String? = nil, hardwareKey: VaultHardwareKey? = nil, keyDerivation: VaultDatabaseSettings = fastKDF, cipher: VaultCipher = .chacha20) async throws {
        _ = try await KeePassKitVaultLoader(hardwareKeys: yubiKey).createVault(options: VaultCreationOptions(
            fileURL: vaultURL,
            name: "Hardware",
            masterPassword: password ?? self.password,
            hardwareKey: hardwareKey,
            cipher: cipher,
            keyDerivation: keyDerivation
        ))
    }

    private func open(
        password: String? = nil,
        hardwareKey: VaultHardwareKey?,
        device: SoftwareHardwareKey? = nil,
        knownResponse: VaultHardwareKeyResponse? = nil
    ) async throws -> KeePassKitVaultLoader {
        let loader = KeePassKitVaultLoader(hardwareKeys: device ?? yubiKey)
        _ = try await loader.loadVault(
            from: vaultURL,
            masterPassword: password ?? self.password,
            keyFileURL: nil,
            hardwareKey: hardwareKey,
            knownResponse: knownResponse
        )
        return loader
    }

    private func headerSeed() throws -> Data {
        try XCTUnwrap(KDBX4Header(data: Data(contentsOf: vaultURL))?.kdfSeed)
    }

    // MARK: Format

    /// Recomputes the header HMAC from the KDBX 4 spec and KeePassXC's composite key:
    /// SHA-256(SHA-256(password) ‖ SHA-256(HMAC-SHA1(secret, KDF seed))) → KDF → SHA-512(master seed ‖ key ‖ 1)
    /// (KeePassXC's `CompositeKey::rawKey(&seed)`: the hash of the responses follows the static keys).
    func testCompositeKeyMatchesKeePassXCScheme() async throws {
        try await createVault(hardwareKey: yubiKey.key)
        let data = try Data(contentsOf: vaultURL)
        let header = try XCTUnwrap(KDBX4Header(data: data))
        XCTAssertEqual(header.majorVersion, 4)
        let seed = try XCTUnwrap(header.kdfSeed)
        XCTAssertEqual(seed.count, 32)

        // What a YubiKey slot in variable length mode signs: the PKCS#7-padded seed without its padding.
        var message = seed + Data(repeating: 32, count: 32)
        while message.last == 32 {
            message.removeLast()
        }
        let response = Data(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: SymmetricKey(data: secret)))
        let composite = Data(SHA256.hash(data:
            Data(SHA256.hash(data: Data(password.utf8))) + Data(SHA256.hash(data: response))
        ))

        let derivation = try XCTUnwrap(KPKKeyDerivation(parameters: header.kdfParameters))
        let transformed = try XCTUnwrap(derivation.deriveData(composite))
        let hmacBase = Data(SHA512.hash(data: header.masterSeed + transformed + Data([1])))
        let blockKey = Data(SHA512.hash(data: Data(repeating: 0xff, count: 8) + hmacBase))
        let expected = Data(HMAC<SHA256>.authenticationCode(for: header.bytes, using: SymmetricKey(data: blockKey)))
        XCTAssertEqual(header.hmac, expected, "the header HMAC follows from the KeePassXC composite key")

        let withoutResponse = Data(SHA256.hash(data: Data(SHA256.hash(data: Data(password.utf8)))))
        let wrong = try XCTUnwrap(derivation.deriveData(withoutResponse))
        let wrongBase = Data(SHA512.hash(data: header.masterSeed + wrong + Data([1])))
        let wrongKey = Data(SHA512.hash(data: Data(repeating: 0xff, count: 8) + wrongBase))
        XCTAssertNotEqual(header.hmac, Data(HMAC<SHA256>.authenticationCode(for: header.bytes, using: SymmetricKey(data: wrongKey))))
    }

    func testHeaderCheckWithoutHardwareKey() async throws {
        try await createVault()
        let data = try Data(contentsOf: vaultURL)
        let header = try XCTUnwrap(KDBX4Header(data: data))
        let composite = Data(SHA256.hash(data: Data(SHA256.hash(data: Data(password.utf8)))))
        let derivation = try XCTUnwrap(KPKKeyDerivation(parameters: header.kdfParameters))
        let transformed = try XCTUnwrap(derivation.deriveData(composite))
        let hmacBase = Data(SHA512.hash(data: header.masterSeed + transformed + Data([1])))
        let blockKey = Data(SHA512.hash(data: Data(repeating: 0xff, count: 8) + hmacBase))
        XCTAssertEqual(header.hmac, Data(HMAC<SHA256>.authenticationCode(for: header.bytes, using: SymmetricKey(data: blockKey))))
    }

    func testPaddingFollowsKeePassXC() {
        let challenge = Data(repeating: 7, count: 32)
        let padded = HardwareKeyChallenge.padded(challenge)
        XCTAssertEqual(padded.count, 64)
        XCTAssertEqual(padded.suffix(32), Data(repeating: 32, count: 32))
        XCTAssertEqual(HardwareKeyChallenge.variableLengthMessage(padded), challenge)
        XCTAssertNotEqual(
            SoftwareHardwareKey.response(secret: secret, challenge: challenge, variableLength: true),
            SoftwareHardwareKey.response(secret: secret, challenge: challenge, variableLength: false),
            "fixed and variable length slots sign different messages"
        )
    }

    // MARK: Loader

    func testOpensOnlyWithTheHardwareKey() async throws {
        try await createVault(hardwareKey: yubiKey.key)
        _ = try await open(hardwareKey: yubiKey.key)

        do {
            _ = try await open(hardwareKey: nil)
            XCTFail("the password alone doesn't open it")
        } catch {
            XCTAssertEqual(error as? VaultError, .invalidPassword)
        }

        let other = SoftwareHardwareKey(secret: Data(repeating: 9, count: 20))
        do {
            _ = try await open(hardwareKey: other.key, device: other)
            XCTFail("another secret doesn't open it")
        } catch {
            XCTAssertEqual(error as? VaultError, .invalidPassword)
        }
    }

    func testOneChallengePerSession() async throws {
        try await createVault(hardwareKey: yubiKey.key)
        let seed = try headerSeed()
        let afterCreate = yubiKey.challenges
        let loader = try await open(hardwareKey: yubiKey.key)
        XCTAssertEqual(yubiKey.challenges, afterCreate + 1)

        for index in 0..<3 {
            _ = try await loader.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Entry \(index)", username: "u", password: "p"))
        }
        XCTAssertEqual(yubiKey.challenges, afterCreate + 1, "saves reuse the response")
        XCTAssertEqual(try headerSeed(), seed, "the KDF seed stays the same between saves")

        let reopened = try await open(hardwareKey: yubiKey.key)
        let status = try await reopened.maintenanceStatus()
        XCTAssertEqual(status.hardwareKey, yubiKey.key)
    }

    func testDeviceErrorsAreReported() async throws {
        try await createVault(hardwareKey: yubiKey.key)
        yubiKey.isConnected = false
        do {
            _ = try await open(hardwareKey: yubiKey.key)
            XCTFail("no key plugged in")
        } catch {
            XCTAssertEqual(error as? VaultError, .hardwareKeyNotFound(serial: yubiKey.key.serial))
        }

        let noTouch = SoftwareHardwareKey(secret: secret, key: yubiKey.key) { _ in false }
        do {
            _ = try await open(hardwareKey: noTouch.key, device: noTouch)
            XCTFail("never touched")
        } catch {
            XCTAssertEqual(error as? VaultError, .hardwareKeyTimedOut)
        }

        var slot1 = yubiKey.key
        slot1.slot = 1
        yubiKey.isConnected = true
        do {
            _ = try await open(hardwareKey: slot1)
            XCTFail("slot 1 isn't programmed")
        } catch {
            XCTAssertEqual(error as? VaultError, .hardwareKeySlotNotConfigured(slot: 1))
        }
    }

    func testKnownResponseOpensWithoutTheDevice() async throws {
        try await createVault(hardwareKey: yubiKey.key)
        let loader = try await open(hardwareKey: yubiKey.key)
        let stored = try await XCTUnwrapAsync(await loader.hardwareKeyResponse())
        XCTAssertEqual(stored.challenge, try headerSeed())

        yubiKey.isConnected = false
        _ = try await open(hardwareKey: yubiKey.key, knownResponse: stored)

        let stale = VaultHardwareKeyResponse(challenge: Data(repeating: 1, count: 32), response: stored.response)
        do {
            _ = try await open(hardwareKey: yubiKey.key, knownResponse: stale)
            XCTFail("a response for another seed asks the device")
        } catch {
            XCTAssertEqual(error as? VaultError, .hardwareKeyNotFound(serial: yubiKey.key.serial))
        }
    }

    /// KeePassXC writes a new KDF seed on every save; the next merge asks the key once and keeps that seed.
    func testSeedChangedByAnotherClient() async throws {
        try await createVault(hardwareKey: yubiKey.key)
        let loader = try await open(hardwareKey: yubiKey.key)
        let before = yubiKey.challenges

        // Another client saves with a fresh seed.
        let device = yubiKey!
        let key = try XCTUnwrap(KPKCompositeKey(keys: [try XCTUnwrap(KPKPasswordKey(password: password))]))
        key.challengeResponseHandler = { challenge, _ in
            try? device.challengeResponse(challenge!, key: device.key, isCancelled: { false })
        }
        let tree = try KPKTree(data: Data(contentsOf: vaultURL), key: key)
        let entry = KPKEntry()
        entry.title = "From KeePassXC"
        entry.add(to: try XCTUnwrap(tree.root))
        let oldSeed = try headerSeed()
        try tree.encrypt(with: key, format: .kdbx).write(to: vaultURL)
        let newSeed = try headerSeed()
        XCTAssertNotEqual(newSeed, oldSeed)
        let afterExternal = yubiKey.challenges

        _ = try await loader.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Local", username: "", password: ""))
        XCTAssertEqual(yubiKey.challenges, afterExternal + 1, "reading the new file asks the key once")
        _ = try await loader.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Local 2", username: "", password: ""))
        XCTAssertEqual(yubiKey.challenges, afterExternal + 1)
        XCTAssertGreaterThan(afterExternal, before)

        let reopened = try await open(hardwareKey: yubiKey.key)
        let titles = Set(try await reopened.loadVault(from: vaultURL, masterPassword: password, keyFileURL: nil, hardwareKey: yubiKey.key, knownResponse: nil).entries.map(\.title))
        XCTAssertTrue(titles.isSuperset(of: ["From KeePassXC", "Local", "Local 2"]))
    }

    func testChangeMasterKeyAddsKeepsAndRemovesTheHardwareKey() async throws {
        try await createVault()
        let loader = try await open(hardwareKey: nil)
        let plainSeed = try headerSeed()

        _ = try await loader.changeMasterKey(currentPassword: password, currentKeyFileURL: nil, newPassword: nil, keyFile: .keep, hardwareKey: .use(yubiKey.key))
        XCTAssertNotEqual(try headerSeed(), plainSeed, "a new hardware key answers a new seed")
        do {
            _ = try await open(hardwareKey: nil)
            XCTFail("needs the key now")
        } catch {}
        _ = try await open(hardwareKey: yubiKey.key)
        let keySeed = try headerSeed()

        let challenges = yubiKey.challenges
        _ = try await loader.changeMasterKey(currentPassword: password, currentKeyFileURL: nil, newPassword: "new", keyFile: .keep, hardwareKey: .keep)
        XCTAssertEqual(yubiKey.challenges, challenges, "keeping the key keeps the seed and its response")
        XCTAssertEqual(try headerSeed(), keySeed)
        _ = try await open(password: "new", hardwareKey: yubiKey.key)

        _ = try await loader.changeMasterKey(currentPassword: "new", currentKeyFileURL: nil, newPassword: nil, keyFile: .keep, hardwareKey: .remove)
        _ = try await open(password: "new", hardwareKey: nil)
        let removed = try await loader.maintenanceStatus()
        XCTAssertNil(removed.hardwareKey)
    }

    func testHardwareKeyAlone() async throws {
        try await createVault(password: "", hardwareKey: yubiKey.key)
        let loader = try await open(password: "", hardwareKey: yubiKey.key)
        do {
            _ = try await loader.changeMasterKey(currentPassword: "", currentKeyFileURL: nil, newPassword: nil, keyFile: .keep, hardwareKey: .remove)
            XCTFail("removing the only key")
        } catch {
            XCTAssertEqual(error as? VaultError, .emptyMasterKey)
        }
    }

    func testKDBX31() async throws {
        let aes = VaultDatabaseSettings(kdf: .aes, aesRounds: 1_000)
        try await createVault(keyDerivation: aes, cipher: .aes256)
        XCTAssertEqual(try KDBX4Header.majorVersion(of: Data(contentsOf: vaultURL)), 3)
        do {
            _ = try await open(hardwareKey: yubiKey.key)
            XCTFail("KeePassXC's KDBX 3.1 scheme isn't supported")
        } catch {
            XCTAssertEqual(error as? VaultError, .hardwareKeyUnsupportedFormat)
        }

        let loader = try await open(hardwareKey: nil)
        _ = try await loader.changeMasterKey(currentPassword: password, currentKeyFileURL: nil, newPassword: nil, keyFile: .keep, hardwareKey: .use(yubiKey.key))
        XCTAssertEqual(try KDBX4Header.majorVersion(of: Data(contentsOf: vaultURL)), 4, "adding a hardware key saves KDBX 4")
        _ = try await open(hardwareKey: yubiKey.key)
    }
}

/// The parts of a KDBX 4 outer header the format test needs.
struct KDBX4Header {
    let majorVersion: Int
    let masterSeed: Data
    let kdfParameters: [String: Any]
    /// Signatures, version and fields up to and including the end field.
    let bytes: Data
    let hmac: Data

    var kdfSeed: Data? {
        kdfParameters["S"] as? Data
    }

    static func majorVersion(of data: Data) -> Int {
        Int(data[data.startIndex + 10]) | Int(data[data.startIndex + 11]) << 8
    }

    init?(data: Data) {
        let bytes = [UInt8](data)
        majorVersion = Self.majorVersion(of: data)
        guard majorVersion == 4 else {
            return nil
        }
        var offset = 12
        var seed: Data?
        var parameters: Data?
        while offset + 5 <= bytes.count {
            let id = bytes[offset]
            let length = Int(bytes[offset + 1]) | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3]) << 16 | Int(bytes[offset + 4]) << 24
            let value = Data(bytes[(offset + 5)..<(offset + 5 + length)])
            offset += 5 + length
            if id == 0 {
                break
            }
            if id == 4 {
                seed = value
            } else if id == 11 {
                parameters = value
            }
        }
        guard let seed, let parameters, let dictionary = Self.variantDictionary(parameters) else {
            return nil
        }
        masterSeed = seed
        kdfParameters = dictionary
        self.bytes = Data(bytes[0..<offset])
        hmac = Data(bytes[(offset + 32)..<(offset + 64)])
    }

    /// KeePass's VariantDictionary, typed the way KeePassKit expects its KDF parameters.
    private static func variantDictionary(_ data: Data) -> [String: Any]? {
        let bytes = [UInt8](data)
        var offset = 2
        var result: [String: Any] = [:]
        func int(_ start: Int, _ count: Int) -> UInt64 {
            (0..<count).reduce(UInt64(0)) { $0 | UInt64(bytes[start + $1]) << (8 * UInt64($1)) }
        }
        while offset < bytes.count {
            let type = bytes[offset]
            offset += 1
            if type == 0 {
                break
            }
            let nameLength = Int(int(offset, 4))
            offset += 4
            let name = String(decoding: bytes[offset..<(offset + nameLength)], as: UTF8.self)
            offset += nameLength
            let valueLength = Int(int(offset, 4))
            offset += 4
            let value = Data(bytes[offset..<(offset + valueLength)])
            switch type {
            case 0x04:
                result[name] = KPKNumber(unsignedInteger32: UInt32(int(offset, 4)))
            case 0x05:
                result[name] = KPKNumber(unsignedInteger64: int(offset, 8))
            case 0x08:
                result[name] = KPKNumber(bool: bytes[offset] != 0)
            case 0x0C:
                result[name] = KPKNumber(integer32: Int32(truncatingIfNeeded: int(offset, 4)))
            case 0x0D:
                result[name] = KPKNumber(integer64: Int64(bitPattern: int(offset, 8)))
            case 0x18:
                result[name] = String(decoding: value, as: UTF8.self)
            default:
                result[name] = value
            }
            offset += valueLength
        }
        return result
    }
}

func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    let resolved = try await value()
    return try XCTUnwrap(resolved, file: file, line: line)
}

@MainActor
final class HardwareKeyViewModelTests: XCTestCase {
    private var directory: URL!
    private var vaultURL: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var settings: AppSettingsStore!
    private let biometrics = FakeBiometricCredentialStore()
    private let yubiKey = SoftwareHardwareKey(secret: Data(repeating: 0x42, count: 20))

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        vaultURL = directory.appendingPathComponent("Model.kdbx")
        suiteName = "HardwareKeyViewModelTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        settings = AppSettingsStore(userDefaults: defaults)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeModel() -> AppViewModel {
        AppViewModel(
            vaultLoader: KeePassKitVaultLoader(hardwareKeys: yubiKey),
            settingsStore: settings,
            userDefaults: defaults,
            biometricCredentialStore: biometrics,
            hardwareKeyDevice: yubiKey
        )
    }

    private func createVault(with model: AppViewModel) async throws {
        try await model.createVault(options: VaultCreationOptions(
            fileURL: vaultURL,
            name: "Model",
            masterPassword: "pw",
            hardwareKey: yubiKey.key,
            keyDerivation: VaultDatabaseSettings(kdf: .argon2id, argonIterations: 1, argonMemoryMiB: 8, argonParallelism: 1)
        ))
    }

    func testHardwareKeyIsRememberedPerDatabase() async throws {
        let model = makeModel()
        try await createVault(with: model)
        XCTAssertEqual(model.selectedHardwareKey, yubiKey.key)
        model.lockVault(reason: .userInitiated)
        await model.finishPendingLock()

        let relaunched = makeModel()
        XCTAssertEqual(relaunched.selectedHardwareKey, yubiKey.key, "restored with the database selection")
        await relaunched.unlock(masterPassword: "pw")
        XCTAssertTrue(relaunched.loadState.isUnlocked)

        relaunched.lockVault(reason: .userInitiated)
        await relaunched.finishPendingLock()
        relaunched.selectHardwareKey(nil)
        await relaunched.unlock(masterPassword: "pw")
        XCTAssertFalse(relaunched.loadState.isUnlocked, "the password alone doesn't open it")
        XCTAssertEqual(settings.hardwareKey(for: vaultURL), yubiKey.key, "a failed unlock doesn't forget the key")
    }

    func testUnlockAsksToConnectTheKey() async throws {
        let model = makeModel()
        try await createVault(with: model)
        model.lockVault(reason: .userInitiated)
        await model.finishPendingLock()

        yubiKey.isConnected = false
        await model.unlock(masterPassword: "pw")
        guard case .failed(let message) = model.loadState else {
            return XCTFail("expected a failure, got \(model.loadState)")
        }
        XCTAssertEqual(message, VaultError.hardwareKeyNotFound(serial: yubiKey.key.serial).errorDescription)

        yubiKey.isConnected = true
        await model.refreshHardwareKeys()
        XCTAssertEqual(model.connectedHardwareKeys, [yubiKey.key])
        XCTAssertTrue(model.isSelectedHardwareKeyConnected)
    }

    func testTouchIDWithoutTheHardwareKey() async throws {
        let model = makeModel()
        try await createVault(with: model)
        settings.setTouchIDEnabled(true, for: vaultURL)
        model.lockVault(reason: .userInitiated)
        await model.finishPendingLock()
        await model.unlock(masterPassword: "pw")
        XCTAssertNil(biometrics.responses[vaultURL.standardizedFileURL.path], "off by default")

        await model.setTouchIDSkipsHardwareKey(true)
        let stored = try XCTUnwrap(biometrics.responses[vaultURL.standardizedFileURL.path])
        model.lockVault(reason: .userInitiated)
        await model.finishPendingLock()

        yubiKey.isConnected = false
        let challenges = yubiKey.challenges
        await model.unlockWithBiometrics()
        XCTAssertTrue(model.loadState.isUnlocked, "the stored response stands in for the key")
        XCTAssertEqual(yubiKey.challenges, challenges)
        XCTAssertEqual(biometrics.responses[vaultURL.standardizedFileURL.path], stored)

        await model.setTouchIDSkipsHardwareKey(false)
        XCTAssertNil(biometrics.responses[vaultURL.standardizedFileURL.path], "turning it off deletes the response")
        model.lockVault(reason: .userInitiated)
        await model.finishPendingLock()
        await model.unlockWithBiometrics()
        XCTAssertFalse(model.loadState.isUnlocked, "without the stored response the key is needed again")
    }

    func testChangeMasterKeyRemovesTheHardwareKey() async throws {
        let model = makeModel()
        try await createVault(with: model)
        try await model.changeMasterKey(currentPassword: "pw", newPassword: "", keyFile: .keep, hardwareKey: .remove)
        XCTAssertNil(model.selectedHardwareKey)
        XCTAssertNil(settings.hardwareKey(for: vaultURL))
        model.lockVault(reason: .userInitiated)
        await model.finishPendingLock()
        await model.unlock(masterPassword: "pw")
        XCTAssertTrue(model.loadState.isUnlocked)
    }
}
