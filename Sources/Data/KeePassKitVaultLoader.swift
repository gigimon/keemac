import Domain
import Foundation
import KeePassKit

public actor KeePassKitVaultLoader: VaultLoading, VaultEditing, VaultSessionControlling {
    private final class TreeEditingDelegate: NSObject, KPKTreeDelegate {
        func shouldEdit(_ tree: KPKTree) -> Bool {
            true
        }
    }

    private struct Session {
        let fileURL: URL
        let key: KPKCompositeKey
        let format: KPKDatabaseFormat
        let tree: KPKTree
        let editingDelegate: TreeEditingDelegate
    }

    private struct ResolvedOTP {
        let configuration: VaultOTPConfiguration
        let storageStyle: VaultOTPStorageStyle
    }

    private var session: Session?

    public init() {}

    public func clearLoadedSession() async {
        session = nil
    }

    public func loadVault(from fileURL: URL, masterPassword: String, keyFileURL: URL?) async throws -> LoadedVault {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw VaultError.fileReadFailure(path: fileURL.path)
        }

        if let keyFileURL {
            guard FileManager.default.fileExists(atPath: keyFileURL.path) else {
                throw VaultError.fileReadFailure(path: keyFileURL.path)
            }
        }

        guard !masterPassword.isEmpty || keyFileURL != nil else {
            throw VaultError.invalidPassword
        }

        let compositeKey = try makeCompositeKey(masterPassword: masterPassword, keyFileURL: keyFileURL)

        let tree: KPKTree
        do {
            tree = try loadTree(from: fileURL, key: compositeKey)
        } catch {
            throw Self.mapKeePassError(error as NSError)
        }

        let editingDelegate = TreeEditingDelegate()
        tree.delegate = editingDelegate

        let format = Self.preferredSaveFormat(for: fileURL, minimumVersionFormat: tree.minimumVersion.format)
        let loadedSession = Session(
            fileURL: fileURL,
            key: compositeKey,
            format: format,
            tree: tree,
            editingDelegate: editingDelegate
        )
        session = loadedSession

        return Self.mapTree(tree, fileURL: fileURL)
    }

    public func createEntry(inGroupPath groupPath: String?, form: VaultEntryForm) async throws -> LoadedVault {
        guard let currentSession = session else {
            throw VaultError.parseFailure(details: "Vault is not loaded for editing.")
        }

        guard let parentGroup = Self.findGroup(in: currentSession.tree, path: groupPath) else {
            throw VaultError.parseFailure(details: "Cannot find target group for new entry.")
        }

        let entry = currentSession.tree.createEntry(parentGroup)
        entry.add(to: parentGroup)
        try Self.apply(form: form, to: entry)

        try save(session: currentSession)
        return Self.mapTree(currentSession.tree, fileURL: currentSession.fileURL)
    }

    public func updateEntry(id: UUID, form: VaultEntryForm) async throws -> LoadedVault {
        guard let currentSession = session else {
            throw VaultError.parseFailure(details: "Vault is not loaded for editing.")
        }

        guard let entry = Self.findEntry(in: currentSession.tree, id: id) else {
            throw VaultError.parseFailure(details: "Entry to update was not found.")
        }

        try Self.apply(form: form, to: entry)

        try save(session: currentSession)
        return Self.mapTree(currentSession.tree, fileURL: currentSession.fileURL)
    }

    public func deleteEntry(id: UUID) async throws -> LoadedVault {
        guard let currentSession = session else {
            throw VaultError.parseFailure(details: "Vault is not loaded for editing.")
        }

        guard let entry = Self.findEntry(in: currentSession.tree, id: id) else {
            throw VaultError.parseFailure(details: "Entry to delete was not found.")
        }

        entry.trashOrRemove()

        try save(session: currentSession)
        return Self.mapTree(currentSession.tree, fileURL: currentSession.fileURL)
    }

    public func createGroup(inParentPath parentPath: String?, title: String, iconID: Int?) async throws -> LoadedVault {
        guard let currentSession = session else {
            throw VaultError.parseFailure(details: "Vault is not loaded for editing.")
        }

        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else {
            throw VaultError.parseFailure(details: "Group title cannot be empty.")
        }

        guard let parentGroup = Self.findGroup(in: currentSession.tree, path: parentPath) else {
            throw VaultError.parseFailure(details: "Cannot find parent group for new group.")
        }

        let group = currentSession.tree.createGroup(parentGroup)
        group.add(to: parentGroup)
        group.title = normalizedTitle
        group.iconId = iconID ?? Int(KPKEntry.defaultIcon())

        try save(session: currentSession)
        return Self.mapTree(currentSession.tree, fileURL: currentSession.fileURL)
    }

    public func updateGroup(path: String, title: String, iconID: Int?) async throws -> LoadedVault {
        guard let currentSession = session else {
            throw VaultError.parseFailure(details: "Vault is not loaded for editing.")
        }

        let normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPath.isEmpty else {
            throw VaultError.parseFailure(details: "Cannot edit root group.")
        }

        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else {
            throw VaultError.parseFailure(details: "Group title cannot be empty.")
        }

        guard let group = Self.findGroup(in: currentSession.tree, path: normalizedPath) else {
            throw VaultError.parseFailure(details: "Group to edit was not found.")
        }

        group.title = normalizedTitle
        group.iconId = iconID ?? Int(KPKEntry.defaultIcon())

        try save(session: currentSession)
        return Self.mapTree(currentSession.tree, fileURL: currentSession.fileURL)
    }

    public func deleteGroup(path: String) async throws -> LoadedVault {
        guard let currentSession = session else {
            throw VaultError.parseFailure(details: "Vault is not loaded for editing.")
        }

        let normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPath.isEmpty else {
            throw VaultError.parseFailure(details: "Cannot delete root group.")
        }

        guard let group = Self.findGroup(in: currentSession.tree, path: normalizedPath) else {
            throw VaultError.parseFailure(details: "Group to delete was not found.")
        }
        guard group.parent != nil else {
            throw VaultError.parseFailure(details: "Cannot delete root group.")
        }

        group.trashOrRemove()

        try save(session: currentSession)
        return Self.mapTree(currentSession.tree, fileURL: currentSession.fileURL)
    }

    private func makeCompositeKey(masterPassword: String, keyFileURL: URL?) throws -> KPKCompositeKey {
        var keyParts: [KPKKey] = []

        if !masterPassword.isEmpty {
            guard let passwordKey = KPKPasswordKey(password: masterPassword) else {
                throw VaultError.invalidPassword
            }
            keyParts.append(passwordKey)
        }

        if let keyFileURL {
            let keyFileData: Data
            do {
                keyFileData = try Data(contentsOf: keyFileURL, options: [.uncached])
            } catch {
                throw VaultError.fileReadFailure(path: keyFileURL.path)
            }

            guard let fileKey = KPKFileKey(keyFileData: keyFileData) else {
                throw VaultError.invalidPassword
            }
            keyParts.append(fileKey)
        }

        guard !keyParts.isEmpty else {
            throw VaultError.invalidPassword
        }

        return KPKCompositeKey(keys: keyParts)
    }

    private func loadTree(from fileURL: URL, key: KPKCompositeKey) throws -> KPKTree {
        let accessed = fileURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        return try KPKTree(contentsOf: fileURL, key: key)
    }

    private func save(session: Session) throws {
        let accessed = session.fileURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                session.fileURL.stopAccessingSecurityScopedResource()
            }
        }

        try createBackup(for: session.fileURL)

        let encryptedData: Data
        do {
            encryptedData = try session.tree.encrypt(with: session.key, format: session.format)
        } catch {
            throw Self.mapKeePassError(error as NSError)
        }

        let directory = session.fileURL.deletingLastPathComponent()
        let temporaryURL = directory.appendingPathComponent(".\(session.fileURL.lastPathComponent).tmp-\(UUID().uuidString)")
        try encryptedData.write(to: temporaryURL, options: [.atomic])

        do {
            _ = try FileManager.default.replaceItemAt(
                session.fileURL,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: [.usingNewMetadataOnly]
            )
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw VaultError.fileReadFailure(path: session.fileURL.path)
        }
    }

    private func createBackup(for fileURL: URL) throws {
        let backupURL = URL(fileURLWithPath: fileURL.path + ".bak")

        if FileManager.default.fileExists(atPath: backupURL.path) {
            try FileManager.default.removeItem(at: backupURL)
        }

        try FileManager.default.copyItem(at: fileURL, to: backupURL)
    }

    private static func mapTree(_ tree: KPKTree, fileURL: URL) -> LoadedVault {
        let allGroups = ([tree.root].compactMap { $0 } + tree.allGroups)
            .filter { !$0.isTrashed }

        let groups = allGroups
            .map {
                VaultGroup(
                    id: UUID(uuidString: $0.uuid.uuidString) ?? UUID(),
                    title: $0.title,
                    path: $0.breadcrumb,
                    iconPNGData: iconData(from: $0.icon),
                    iconID: normalizedIconID($0.iconId)
                )
            }
            .sorted { lhs, rhs in
                lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
            }

        let allEntries = tree.allEntries.filter { !$0.isHistory && !$0.isMeta && !$0.isTrashed }
        var entries: [VaultEntry] = []
        entries.reserveCapacity(allEntries.count)

        for entry in allEntries {
            let url = entry.url.isEmpty ? nil : URL(string: entry.url)
            let customFields = entry.customAttributes
                .filter { !isSystemCustomFieldKey($0.key) }
                .map {
                    VaultCustomField(
                        key: $0.key,
                        value: $0.value,
                        isProtected: $0.protect
                    )
                }
                .sorted { lhs, rhs in
                    lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
                }

            let otp = makeOTPConfiguration(from: entry)
            entries.append(
                VaultEntry(
                    id: UUID(uuidString: entry.uuid.uuidString) ?? UUID(),
                    groupPath: entry.parent?.breadcrumb ?? "",
                    title: entry.title,
                    username: entry.username.isEmpty ? nil : entry.username,
                    password: entry.password.isEmpty ? nil : entry.password,
                    url: url,
                    notes: entry.notes.isEmpty ? nil : entry.notes,
                    customFields: customFields,
                    iconPNGData: iconData(from: entry.icon),
                    iconID: normalizedIconID(entry.iconId),
                    otp: otp?.configuration,
                    otpStorageStyle: otp?.storageStyle
                )
            )
        }

        entries.sort { lhs, rhs in
            lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }

        return LoadedVault(
            summary: VaultSummary(
                fileName: fileURL.lastPathComponent,
                groupCount: groups.count,
                entryCount: entries.count
            ),
            groups: groups,
            entries: entries
        )
    }

    private static func findGroup(in tree: KPKTree, path: String?) -> KPKGroup? {
        guard let path, !path.isEmpty else {
            return tree.root
        }

        let groups = [tree.root].compactMap { $0 } + tree.allGroups
        return groups.first { $0.breadcrumb == path }
    }

    private static func findEntry(in tree: KPKTree, id: UUID) -> KPKEntry? {
        tree.allEntries.first { $0.uuid.uuidString.lowercased() == id.uuidString.lowercased() }
    }

    private static func apply(form: VaultEntryForm, to entry: KPKEntry) throws {
        let normalizedTitle = form.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else {
            throw VaultError.parseFailure(details: "Entry title cannot be empty.")
        }

        entry.title = normalizedTitle
        entry.username = form.username
        entry.password = form.password
        entry.url = form.url
        entry.notes = form.notes
        entry.iconId = form.iconID ?? Int(KPKEntry.defaultIcon())

        try applyCustomFields(form.customFields, to: entry)
        try applyOTP(form.otp, to: entry, title: normalizedTitle)
    }

    private static func applyCustomFields(_ customFields: [VaultCustomFieldForm], to entry: KPKEntry) throws {
        var seenKeys = Set<String>()
        for field in customFields {
            let key = field.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                throw VaultError.parseFailure(details: "Custom field key cannot be empty.")
            }
            let normalized = key.lowercased()
            guard !seenKeys.contains(normalized) else {
                throw VaultError.parseFailure(details: "Custom field keys must be unique.")
            }
            seenKeys.insert(normalized)
        }

        for attribute in entry.customAttributes where !isSystemCustomFieldKey(attribute.key) {
            entry.removeCustomAttribute(attribute)
        }

        for field in customFields {
            let key = field.key.trimmingCharacters(in: .whitespacesAndNewlines)
            let attribute = KPKAttribute(key: key, value: field.value, isProtected: field.isProtected)
            entry.addCustomAttribute(attribute)
        }
    }

    private static func applyOTP(_ otp: VaultOTPForm?, to entry: KPKEntry, title: String) throws {
        clearOTPAttributes(on: entry)

        guard let otp else {
            return
        }

        let secretData = try decodeOTPSecretInput(otp.secret)
        let clampedDigits = min(max(otp.digits, 6), 9)
        let period = max(otp.period, 1)

        switch otp.storageStyle {
        case .otpAuth:
            let secret = encodeBase32(secretData)
            let encodedLabel = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? title
            let algorithm = otp.algorithm.rawValue.uppercased()
            let otpURL = "otpauth://totp/\(encodedLabel)?secret=\(secret)&algorithm=\(algorithm)&digits=\(clampedDigits)&period=\(period)"
            upsertCustomAttribute(on: entry, key: kKPKAttributeKeyOTPOAuthURL, value: otpURL, protect: false)

        case .native:
            let secret = encodeBase32(secretData)
            upsertCustomAttribute(on: entry, key: kKPKAttributeKeyTimeOTPSecretBase32, value: secret, protect: true)
            upsertCustomAttribute(on: entry, key: kKPKAttributeKeyTimeOTPLength, value: String(clampedDigits), protect: false)
            upsertCustomAttribute(on: entry, key: kKPKAttributeKeyTimeOTPPeriod, value: String(period), protect: false)
            upsertCustomAttribute(on: entry, key: kKPKAttributeKeyTimeOTPAlgorithm, value: otpAlgorithmValue(otp.algorithm), protect: false)
            upsertCustomAttribute(on: entry, key: kKPKAttributeKeyTimeOTPSettings, value: "period=\(period);digits=\(clampedDigits)", protect: false)
        }
    }

    private static func decodeOTPSecretInput(_ value: String) throws -> Data {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw VaultError.parseFailure(details: "OTP secret cannot be empty.")
        }

        if let base32 = decodeBase32(normalized), !base32.isEmpty {
            return base32
        }
        if let base64 = Data(base64Encoded: normalized), !base64.isEmpty {
            return base64
        }
        if let hex = decodeHex(normalized), !hex.isEmpty {
            return hex
        }

        throw VaultError.parseFailure(details: "OTP secret must be valid Base32, Base64, or Hex.")
    }

    private static func clearOTPAttributes(on entry: KPKEntry) {
        for key in otpReservedCustomKeys {
            if let attribute = entry.customAttribute(withKey: key) {
                entry.removeCustomAttribute(attribute)
            }
        }
    }

    private static func upsertCustomAttribute(on entry: KPKEntry, key: String, value: String, protect: Bool) {
        if let existing = entry.customAttribute(withKey: key) {
            existing.value = value
            existing.protect = protect
            return
        }

        let attribute = KPKAttribute(key: key, value: value, isProtected: protect)
        entry.addCustomAttribute(attribute)
    }

    private static func otpAlgorithmValue(_ algorithm: VaultOTPAlgorithm) -> String {
        switch algorithm {
        case .sha1:
            return kKPKAttributeValueTimeOTPHmacSha1
        case .sha256:
            return kKPKAttributeValueTimeOTPHmacSha256
        case .sha512:
            return kKPKAttributeValueTimeOTPHmacSha512
        }
    }

    private static let otpReservedCustomKeys: Set<String> = [
        kKPKAttributeKeyOTPOAuthURL,
        kKPKAttributeKeyHmacOTPSecret,
        kKPKAttributeKeyHmacOTPSecretHex,
        kKPKAttributeKeyHmacOTPSecretBase32,
        kKPKAttributeKeyHmacOTPSecretBase64,
        kKPKAttributeKeyHmacOTPCounter,
        kKPKAttributeKeyTimeOTPSecret,
        kKPKAttributeKeyTimeOTPSecretHex,
        kKPKAttributeKeyTimeOTPSecretBase32,
        kKPKAttributeKeyTimeOTPSecretBase64,
        kKPKAttributeKeyTimeOTPLength,
        kKPKAttributeKeyTimeOTPPeriod,
        kKPKAttributeKeyTimeOTPAlgorithm,
        kKPKAttributeKeyTimeOTPSeed,
        kKPKAttributeKeyTimeOTPSettings
    ]

    private static func isSystemCustomFieldKey(_ key: String) -> Bool {
        otpReservedCustomKeys.contains(key)
    }

    private static func normalizedDatabaseFormat(_ format: KPKDatabaseFormat) -> KPKDatabaseFormat {
        if format.rawValue == 0 {
            return KPKDatabaseFormat(rawValue: 2) ?? format
        }
        return format
    }

    private static func preferredSaveFormat(for fileURL: URL, minimumVersionFormat: KPKDatabaseFormat) -> KPKDatabaseFormat {
        let normalizedMinimum = normalizedDatabaseFormat(minimumVersionFormat)

        if fileURL.pathExtension.lowercased() == "kdbx" {
            return KPKDatabaseFormat(rawValue: 2) ?? normalizedMinimum
        }
        return normalizedMinimum
    }

    static func mapKeePassError(_ error: NSError?) -> VaultError {
        guard let error else {
            return .unknown(details: nil)
        }

        if error.domain == KPKErrorDomain {
            let normalized = error.localizedDescription.lowercased()

            if normalized.contains("password")
                || normalized.contains("keyfile")
                || normalized.contains("header hash") {
                return .invalidPassword
            }
            if normalized.contains("unsupported") {
                return .unsupportedKDBXVariant
            }
            return .parseFailure(details: error.localizedDescription)
        }

        return .unknown(details: error.localizedDescription)
    }

    private static func makeOTPConfiguration(from entry: KPKEntry) -> ResolvedOTP? {
        guard entry.hasTimeOTP, !entry.hasSteamOTP else {
            return nil
        }

        if let fromURL = parseOTPAuthConfiguration(from: entry) {
            return fromURL
        }
        return parseNativeTimeOTPConfiguration(from: entry)
    }

    private static func iconData(from icon: KPKIcon?) -> Data? {
        guard
            let encodedString = icon?.encodedString,
            !encodedString.isEmpty
        else {
            return nil
        }
        return Data(base64Encoded: encodedString)
    }

    private static func normalizedIconID(_ rawValue: Int) -> Int? {
        guard rawValue >= 0 else {
            return nil
        }
        return rawValue
    }

    private static func parseOTPAuthConfiguration(from entry: KPKEntry) -> ResolvedOTP? {
        guard
            let otpURLString = entry.valueForAttribute(withKey: kKPKAttributeKeyOTPOAuthURL),
            let urlComponents = URLComponents(string: otpURLString)
        else {
            return nil
        }

        if let host = urlComponents.host?.lowercased(), host == "steam" {
            return nil
        }

        let queryItems = Dictionary(
            uniqueKeysWithValues: (urlComponents.queryItems ?? []).map { item in
                (item.name.lowercased(), item.value ?? "")
            }
        )

        guard let secretText = queryItems["secret"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !secretText.isEmpty else {
            return nil
        }

        guard let secret = decodeBase32(secretText) ?? Data(base64Encoded: secretText) else {
            return nil
        }

        let digits = clampDigits(Int(queryItems["digits"] ?? ""))
        let period = max(Int(queryItems["period"] ?? "") ?? 30, 1)
        let algorithm = parseOTPAlgorithm(queryItems["algorithm"])

        return ResolvedOTP(
            configuration: VaultOTPConfiguration(
                secret: secret,
                digits: digits,
                period: period,
                timeBase: 0,
                algorithm: algorithm
            ),
            storageStyle: .otpAuth
        )
    }

    private static func parseNativeTimeOTPConfiguration(from entry: KPKEntry) -> ResolvedOTP? {
        let secret = decodeTimeOTPSecret(from: entry)
        guard !secret.isEmpty else {
            return nil
        }

        let settingsValues = parseSettings(entry.valueForAttribute(withKey: kKPKAttributeKeyTimeOTPSettings))
        let periodFromSettings = settingsValues.first
        let digitsFromSettings = settingsValues.dropFirst().first

        let period = max(
            Int(entry.valueForAttribute(withKey: kKPKAttributeKeyTimeOTPPeriod) ?? "")
                ?? periodFromSettings
                ?? 30,
            1
        )
        let digits = clampDigits(
            Int(entry.valueForAttribute(withKey: kKPKAttributeKeyTimeOTPLength) ?? "")
                ?? digitsFromSettings
        )
        let timeBase = TimeInterval(entry.valueForAttribute(withKey: kKPKAttributeKeyTimeOTPSeed) ?? "") ?? 0
        let algorithm = parseOTPAlgorithm(entry.valueForAttribute(withKey: kKPKAttributeKeyTimeOTPAlgorithm))

        return ResolvedOTP(
            configuration: VaultOTPConfiguration(
                secret: secret,
                digits: digits,
                period: period,
                timeBase: timeBase,
                algorithm: algorithm
            ),
            storageStyle: .native
        )
    }

    private static func decodeTimeOTPSecret(from entry: KPKEntry) -> Data {
        if let base32 = entry.valueForAttribute(withKey: kKPKAttributeKeyTimeOTPSecretBase32),
           let secret = decodeBase32(base32) {
            return secret
        }
        if let base64 = entry.valueForAttribute(withKey: kKPKAttributeKeyTimeOTPSecretBase64),
           let secret = Data(base64Encoded: base64) {
            return secret
        }
        if let hex = entry.valueForAttribute(withKey: kKPKAttributeKeyTimeOTPSecretHex),
           let secret = decodeHex(hex) {
            return secret
        }
        if let generic = entry.valueForAttribute(withKey: kKPKAttributeKeyTimeOTPSecret) {
            if let secret = decodeBase32(generic) {
                return secret
            }
            if let secret = Data(base64Encoded: generic) {
                return secret
            }
            if let secret = decodeHex(generic) {
                return secret
            }
        }
        return Data()
    }

    private static func parseOTPAlgorithm(_ value: String?) -> VaultOTPAlgorithm {
        guard let value else {
            return .sha1
        }

        let normalized = value.lowercased()
        if normalized == kKPKAttributeValueTimeOTPHmacSha256.lowercased() || normalized.contains("256") {
            return .sha256
        }
        if normalized == kKPKAttributeValueTimeOTPHmacSha512.lowercased() || normalized.contains("512") {
            return .sha512
        }
        return .sha1
    }

    private static func parseSettings(_ value: String?) -> [Int] {
        guard let value else {
            return []
        }

        return value
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
    }

    private static func clampDigits(_ value: Int?) -> Int {
        min(max(value ?? 6, 1), 9)
    }

    private static func decodeHex(_ value: String) -> Data? {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")

        guard normalized.count.isMultiple(of: 2) else {
            return nil
        }

        var data = Data(capacity: normalized.count / 2)
        var index = normalized.startIndex
        while index < normalized.endIndex {
            let next = normalized.index(index, offsetBy: 2)
            let byteString = normalized[index..<next]
            guard let byte = UInt8(byteString, radix: 16) else {
                return nil
            }
            data.append(byte)
            index = next
        }
        return data
    }

    private static func decodeBase32(_ value: String) -> Data? {
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
        var lookup: [Character: UInt8] = [:]
        for (index, char) in alphabet.enumerated() {
            lookup[char] = UInt8(index)
        }

        let normalized = value.uppercased()
            .filter { $0.isLetter || $0.isNumber || $0 == "=" }
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))

        guard !normalized.isEmpty else {
            return nil
        }

        var buffer: UInt64 = 0
        var bitsLeft = 0
        var result = Data()

        for character in normalized {
            guard let v = lookup[character] else {
                return nil
            }

            buffer = (buffer << 5) | UInt64(v)
            bitsLeft += 5

            while bitsLeft >= 8 {
                let byte = UInt8((buffer >> UInt64(bitsLeft - 8)) & 0xff)
                result.append(byte)
                bitsLeft -= 8
            }
        }

        return result.isEmpty ? nil : result
    }

    private static func encodeBase32(_ data: Data) -> String {
        guard !data.isEmpty else {
            return ""
        }

        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var output = ""
        var buffer: UInt32 = 0
        var bitsLeft = 0

        for byte in data {
            buffer = (buffer << 8) | UInt32(byte)
            bitsLeft += 8

            while bitsLeft >= 5 {
                let index = Int((buffer >> UInt32(bitsLeft - 5)) & 0x1f)
                output.append(alphabet[index])
                bitsLeft -= 5
            }
        }

        if bitsLeft > 0 {
            let index = Int((buffer << UInt32(5 - bitsLeft)) & 0x1f)
            output.append(alphabet[index])
        }

        return output
    }
}
