import Foundation

/// When the agent asks before a key is used.
public enum VaultSSHConfirmation: String, Sendable, CaseIterable, Codable, Equatable {
    case everyTime
    /// Once, then the key works until the database locks.
    case oncePerUnlock
    case never
}

/// A server a key is for: a host name, `*.example.com` or `[host]:2222`.
public struct VaultSSHHost: Sendable, Equatable, Hashable, Codable {
    public var pattern: String
    /// Set when the agent remembered the host by itself (the server accepted the key).
    public var learnedAt: Date?

    public init(pattern: String, learnedAt: Date? = nil) {
        self.pattern = pattern
        self.learnedAt = learnedAt
    }

    public var isLearned: Bool { learnedAt != nil }
}

/// An entry's SSH agent settings. The KeeAgent part lives in the `KeeAgent.settings` attachment,
/// readable by KeePassXC and KeePass + KeeAgent; hosts and confirmation are KeeMac's, in entry CustomData.
public struct VaultSSHAgentSettings: Sendable, Equatable {
    public static let attachmentName = "KeeAgent.settings"
    public static let customDataKey = "KeeMac.SSHAgent"

    public var isEnabled: Bool
    /// The attachment holding the private key.
    public var keyAttachmentName: String?
    /// A key file on disk instead of an attachment (KeeAgent's "file" location).
    public var keyFilePath: String?
    public var hosts: [VaultSSHHost]
    /// Nil uses the app's default for new keys.
    public var confirmation: VaultSSHConfirmation?

    // KeeAgent options KeeMac doesn't use but writes back unchanged.
    public var addAtDatabaseOpen: Bool
    public var removeAtDatabaseClose: Bool
    public var useConfirmConstraint: Bool
    public var useLifetimeConstraint: Bool
    public var lifetimeSeconds: Int

    public init(
        isEnabled: Bool = true,
        keyAttachmentName: String? = nil,
        keyFilePath: String? = nil,
        hosts: [VaultSSHHost] = [],
        confirmation: VaultSSHConfirmation? = nil,
        addAtDatabaseOpen: Bool = true,
        removeAtDatabaseClose: Bool = true,
        useConfirmConstraint: Bool = false,
        useLifetimeConstraint: Bool = false,
        lifetimeSeconds: Int = 600
    ) {
        self.isEnabled = isEnabled
        self.keyAttachmentName = keyAttachmentName
        self.keyFilePath = keyFilePath
        self.hosts = hosts
        self.confirmation = confirmation
        self.addAtDatabaseOpen = addAtDatabaseOpen
        self.removeAtDatabaseClose = removeAtDatabaseClose
        self.useConfirmConstraint = useConfirmConstraint
        self.useLifetimeConstraint = useLifetimeConstraint
        self.lifetimeSeconds = lifetimeSeconds
    }

    // MARK: KeeMac part (CustomData JSON)

    private struct Extras: Codable {
        var hosts: [VaultSSHHost]?
        var confirmation: VaultSSHConfirmation?
    }

    /// JSON for the entry's CustomData; nil when there is nothing to keep.
    public var customDataValue: String? {
        guard !hosts.isEmpty || confirmation != nil else { return nil }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        let data = try? encoder.encode(Extras(hosts: hosts.isEmpty ? nil : hosts, confirmation: confirmation))
        return data.map { String(decoding: $0, as: UTF8.self) }
    }

    public mutating func applyCustomData(_ value: String?) {
        guard let value else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let extras = try? decoder.decode(Extras.self, from: Data(value.utf8)) else { return }
        hosts = extras.hosts ?? []
        confirmation = extras.confirmation
    }

    // MARK: KeeAgent part (XML attachment)

    /// Reads `KeeAgent.settings` (UTF-16 with BOM from KeePassXC, UTF-8 from others).
    public init?(keeAgentData data: Data) {
        let parser = KeeAgentSettingsParser(data: data)
        guard let values = parser.parse() else { return nil }
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            values[key].map { $0.lowercased() == "true" } ?? fallback
        }
        let type = values["SelectedType"]?.lowercased()
        let attachment = values["AttachmentName"].flatMap { $0.isEmpty ? nil : $0 }
        let file = values["FileName"].flatMap { $0.isEmpty ? nil : $0 }
        self.init(
            isEnabled: bool("AllowUseOfSshKey", false),
            keyAttachmentName: type == "file" ? nil : attachment,
            keyFilePath: type == "file" ? file : nil,
            addAtDatabaseOpen: bool("AddAtDatabaseOpen", true),
            removeAtDatabaseClose: bool("RemoveAtDatabaseClose", true),
            useConfirmConstraint: bool("UseConfirmConstraintWhenAdding", false),
            useLifetimeConstraint: bool("UseLifetimeConstraintWhenAdding", false),
            lifetimeSeconds: values["LifetimeConstraintDuration"].flatMap(Int.init) ?? 600
        )
    }

    /// `KeeAgent.settings` as KeePassXC writes it: UTF-16 little-endian with a BOM.
    public var keeAgentData: Data {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        let isFile = keyAttachmentName == nil && keyFilePath != nil
        let xml = """
        <?xml version="1.0" encoding="UTF-16"?>
        <EntrySettings xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
          <AllowUseOfSshKey>\(isEnabled)</AllowUseOfSshKey>
          <AddAtDatabaseOpen>\(addAtDatabaseOpen)</AddAtDatabaseOpen>
          <RemoveAtDatabaseClose>\(removeAtDatabaseClose)</RemoveAtDatabaseClose>
          <UseConfirmConstraintWhenAdding>\(useConfirmConstraint)</UseConfirmConstraintWhenAdding>
          <UseLifetimeConstraintWhenAdding>\(useLifetimeConstraint)</UseLifetimeConstraintWhenAdding>
          <LifetimeConstraintDuration>\(lifetimeSeconds)</LifetimeConstraintDuration>
          <Location>
            <SelectedType>\(isFile ? "file" : "attachment")</SelectedType>
            <AttachmentName>\(escape(keyAttachmentName ?? ""))</AttachmentName>
            <SaveAttachmentToTempFile>false</SaveAttachmentToTempFile>
            <FileName>\(escape(keyFilePath ?? ""))</FileName>
          </Location>
        </EntrySettings>

        """
        var data = Data([0xFF, 0xFE])
        data.append(xml.data(using: .utf16LittleEndian) ?? Data())
        return data
    }
}

/// Flat element text of a KeeAgent settings file (element names are unique there).
private final class KeeAgentSettingsParser: NSObject, XMLParserDelegate {
    private let data: Data
    private var values: [String: String] = [:]
    private var text = ""
    private var sawRoot = false

    init(data: Data) {
        self.data = data
    }

    func parse() -> [String: String]? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse(), sawRoot else { return nil }
        return values
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        if elementName == "EntrySettings" {
            sawRoot = true
        }
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        values[elementName] = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""
    }
}
