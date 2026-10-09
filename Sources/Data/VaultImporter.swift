import Domain
import Foundation
import KeePassKit
import OSLog

/// Reads files exported by other password managers into `VaultImportItem`s.
public enum VaultImporter {
    private static let logger = Logger(subsystem: "com.keemac.app", category: "import")

    /// Reads `data`, detecting the format unless `format` is given.
    /// A KeePass 1 database throws `keePass1Locked`: it can only be read with `readKeePass1`.
    public static func read(_ data: Data, format: VaultImportFormat? = nil) throws -> VaultImportFile {
        if format == .keePass1 || (format == nil && isKeePass1(data)) {
            throw isKeePass1(data) ? VaultImportError.keePass1Locked : VaultImportError.unreadableKeePass1
        }
        if format == .keePassXML || (format == nil && looksLikeXML(data)) {
            return try readKeePassXML(data)
        }
        if isKDBX(data) {
            throw VaultImportError.unreadable
        }
        guard let text = decodeText(data) else {
            throw VaultImportError.unreadable
        }
        let rows = CSVReader.rows(in: text)
        guard let headerRow = rows.first, headerRow.fields.count > 1 else {
            throw format == nil ? VaultImportError.unreadable : VaultImportError.formatMismatch
        }
        let header = Header(headerRow.fields)
        let resolved: VaultImportFormat
        if let format {
            guard header.fits(format) else {
                throw VaultImportError.formatMismatch
            }
            resolved = format
        } else {
            guard let detected = header.detectedFormat else {
                throw VaultImportError.unrecognizedCSV
            }
            resolved = detected
        }

        var items: [VaultImportItem] = []
        var skipped: [Int] = []
        for row in rows.dropFirst() {
            if row.fields.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                continue
            }
            guard row.fields.count >= header.minimumColumns(for: resolved) else {
                skipped.append(row.line)
                continue
            }
            let record = Record(header: header, fields: row.fields)
            if let item = item(from: record, format: resolved) {
                items.append(item)
            } else {
                skipped.append(row.line)
            }
        }
        return VaultImportFile(format: resolved, items: items, skippedLines: skipped)
    }

    // MARK: - CSV formats

    private static func item(from record: Record, format: VaultImportFormat) -> VaultImportItem? {
        switch format {
        case .keePass1, .keePassXML:
            return nil
        case .bitwarden:
            let type = record["type"].lowercased()
            guard type.isEmpty || type == "login" || type == "note" else {
                return nil
            }
            return finished(VaultImportItem(
                title: record["name"],
                username: record["login_username"],
                password: record["login_password"],
                url: firstURL(record["login_uri"]),
                notes: record["notes"],
                otp: record["login_totp"],
                customFields: bitwardenFields(record["fields"]),
                folder: folderPath(record["folder"], separator: "/"),
                isSecureNote: type == "note"
            ))
        case .onePassword:
            return finished(VaultImportItem(
                title: record["title"],
                username: record["username"],
                password: record["password"],
                url: record.first("url", "website", "urls"),
                notes: record.first("notes", "notesplain"),
                otp: record.first("otpauth", "one-time password"),
                tags: record["tags"].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            ))
        case .chrome:
            return finished(VaultImportItem(
                title: record["name"],
                username: record["username"],
                password: record["password"],
                url: record["url"],
                notes: record.first("note", "notes")
            ))
        case .firefox:
            let url = record["url"]
            if url.hasPrefix("chrome://") {
                return nil
            }
            return finished(VaultImportItem(
                title: "",
                username: record["username"],
                password: record["password"],
                url: url
            ))
        case .safari:
            return finished(VaultImportItem(
                title: record["title"],
                username: record["username"],
                password: record["password"],
                url: record["url"],
                notes: record["notes"],
                otp: record["otpauth"]
            ))
        case .lastPass:
            let url = record["url"]
            let isNote = url == "http://sn"
            return finished(VaultImportItem(
                title: record["name"],
                username: record["username"],
                password: record["password"],
                url: isNote ? "" : url,
                notes: record["extra"],
                otp: record["totp"],
                folder: folderPath(record["grouping"], separator: "\\"),
                isSecureNote: isNote
            ))
        case .keePassXC:
            return finished(VaultImportItem(
                title: record["title"],
                username: record["username"],
                password: record["password"],
                url: record["url"],
                notes: record["notes"],
                otp: record["totp"],
                // The first component is the exported database's root group.
                folder: Array(folderPath(record["group"], separator: "/").dropFirst())
            ))
        }
    }

    /// Fills an empty title from the site or the username.
    private static func finished(_ item: VaultImportItem) -> VaultImportItem? {
        var item = item
        if item.title.trimmingCharacters(in: .whitespaces).isEmpty {
            if let host = URLComponents(string: item.url)?.host, !host.isEmpty {
                item.title = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            } else if !item.username.isEmpty {
                item.title = item.username
            } else if item.password.isEmpty && item.notes.isEmpty {
                return nil
            } else {
                item.title = "Untitled"
            }
        }
        return item
    }

    private static func firstURL(_ value: String) -> String {
        value.split(whereSeparator: { $0 == "," || $0.isNewline }).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    private static func folderPath(_ value: String, separator: Character) -> [String] {
        value.split(separator: separator).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Bitwarden custom fields: one `name: value` per line.
    private static func bitwardenFields(_ value: String) -> [VaultCustomField] {
        value.split(whereSeparator: \.isNewline).compactMap { line in
            guard let colon = line.firstIndex(of: ":") else {
                return nil
            }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let fieldValue = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else {
                return nil
            }
            return VaultCustomField(key: key, value: fieldValue, isProtected: false)
        }
    }

    // MARK: - KeePass XML

    private static func readKeePassXML(_ data: Data) throws -> VaultImportFile {
        let tree: KPKTree
        do {
            tree = try KPKTree(xmlData: data)
        } catch {
            throw VaultImportError.unreadable
        }
        let items = tree.allEntries
            .filter { !$0.isHistory && !$0.isMeta && !$0.isTrashed }
            .map { entry -> VaultImportItem in
                var folder: [String] = []
                var parent = entry.parent
                while let group = parent, group.parent != nil {
                    folder.insert(group.title ?? "", at: 0)
                    parent = group.parent
                }
                let otp = entry.customAttributes?.first { $0.key == kKPKAttributeKeyOTPOAuthURL }?.value ?? (entry.hasTimeOTP ? "totp" : "")
                return VaultImportItem(
                    title: entry.title ?? "",
                    username: entry.username ?? "",
                    password: entry.password ?? "",
                    url: entry.url ?? "",
                    notes: entry.notes ?? "",
                    otp: otp,
                    folder: folder
                )
            }
        return VaultImportFile(format: .keePassXML, items: items, xmlData: data)
    }

    /// Opens a KeePass 1 database. The file is only read; the result imports like KeePass XML
    /// (groups, attachments, notes), without the Backup group KeePass 1 uses as its trash.
    public static func readKeePass1(_ data: Data, password: String, keyFileData: Data?) throws -> VaultImportFile {
        guard isKeePass1(data) else {
            throw VaultImportError.unreadableKeePass1
        }
        var keys: [KPKKey] = []
        if !password.isEmpty, let passwordKey = KPKPasswordKey(password: password) {
            keys.append(passwordKey)
        }
        if let keyFileData {
            guard let fileKey = KPKFileKey(keyFileData: keyFileData) else {
                throw VaultImportError.wrongKey
            }
            keys.append(fileKey)
        }
        guard !keys.isEmpty else {
            throw VaultImportError.wrongKey
        }

        let tree: KPKTree
        do {
            tree = try KPKTree(data: data, key: KPKCompositeKey(keys: keys))
        } catch {
            let nsError = error as NSError
            // Only the error code: KeePassKit's messages never contain secrets, but keep the log minimal anyway.
            logger.error("KeePass 1 read failed (domain: \(nsError.domain, privacy: .public), code: \(nsError.code, privacy: .public))")
            throw isWrongKeyError(nsError) ? VaultImportError.wrongKey : VaultImportError.unreadableKeePass1
        }
        for group in tree.root?.groups ?? [] where group === tree.trash || group.title == "Backup" {
            group.remove()
        }
        guard let xml = tree.xmlData else {
            throw VaultImportError.unreadableKeePass1
        }
        let file = try readKeePassXML(xml)
        return VaultImportFile(format: .keePass1, items: file.items, xmlData: xml)
    }

    /// KeePass 1 has no key check value: a wrong key decrypts to garbage, which then fails to parse
    /// ("Unknown data field. Password wrong?"). Like KeePass 1, treat any failure after a readable header
    /// as a wrong key; a truncated header or an unsupported cipher means the file itself can't be read.
    private static func isWrongKeyError(_ error: NSError) -> Bool {
        guard error.domain == KPKErrorDomain, let code = KPKErrorCode(rawValue: UInt(error.code)) else {
            return false
        }
        switch code {
        case .passwordAndOrKeyfileWrong, .decryptionFailed, .aesDecryptionFailed, .integrityCheckFailed,
             .kdbCorruptTree, .kdbInvalidFieldSize, .kdbInvalidFieldType:
            return true
        default:
            return false
        }
    }

    // MARK: - File sniffing

    /// KeePass 1 shares its first four signature bytes with KDBX; the second signature tells them apart.
    public static func isKeePass1(_ data: Data) -> Bool {
        data.starts(with: [0x03, 0xD9, 0xA2, 0x9A, 0x65, 0xFB, 0x4B, 0xB5])
    }

    private static func looksLikeXML(_ data: Data) -> Bool {
        guard let text = decodeText(data.prefix(512)) else {
            return false
        }
        let start = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return start.hasPrefix("<?xml") || start.hasPrefix("<KeePassFile")
    }

    private static func isKDBX(_ data: Data) -> Bool {
        data.starts(with: [0x03, 0xD9, 0xA2, 0x9A])
    }

    private static func decodeText(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            bytes = bytes.dropFirst(3)
        }
        if let text = String(data: bytes, encoding: .utf8) {
            return text
        }
        return String(data: bytes, encoding: .windowsCP1252)
    }

    // MARK: - Header matching

    private struct Header {
        let names: [String]
        private let index: [String: Int]

        init(_ fields: [String]) {
            names = fields.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            var index: [String: Int] = [:]
            for (position, name) in names.enumerated() where index[name] == nil {
                index[name] = position
            }
            self.index = index
        }

        func position(of name: String) -> Int? {
            index[name]
        }

        private func has(_ required: String...) -> Bool {
            required.allSatisfy { index[$0] != nil }
        }

        func fits(_ format: VaultImportFormat) -> Bool {
            switch format {
            case .keePass1, .keePassXML: return false
            case .bitwarden: return has("name", "login_uri", "login_username", "login_password")
            case .onePassword: return has("title", "username", "password") && (has("url") || has("website") || has("urls"))
            case .chrome: return has("name", "url", "username", "password")
            case .firefox: return has("url", "username", "password")
            case .safari: return has("title", "url", "username", "password")
            case .lastPass: return has("url", "username", "password", "name", "grouping")
            case .keePassXC: return has("group", "title", "username", "password")
            }
        }

        /// Most specific columns first, so similar exports (Safari vs. 1Password) aren't confused.
        var detectedFormat: VaultImportFormat? {
            if fits(.bitwarden) { return .bitwarden }
            if fits(.lastPass) && has("extra") { return .lastPass }
            if fits(.keePassXC) { return .keePassXC }
            if fits(.firefox) && (has("httprealm") || has("formactionorigin") || has("guid")) { return .firefox }
            if fits(.onePassword) && (has("otpauth") && (has("favorite") || has("archived") || has("tags")) || has("website") || has("notesplain")) { return .onePassword }
            if fits(.safari) { return .safari }
            if fits(.chrome) { return .chrome }
            return nil
        }

        /// Rows shorter than this are damaged (columns after the last one we read may be missing).
        func minimumColumns(for format: VaultImportFormat) -> Int {
            let used: [String]
            switch format {
            case .keePass1, .keePassXML: used = []
            case .bitwarden: used = ["name", "login_uri", "login_username", "login_password"]
            case .onePassword: used = ["title", "username", "password"]
            case .chrome: used = ["name", "url", "username", "password"]
            case .firefox: used = ["url", "username", "password"]
            case .safari: used = ["title", "url", "username", "password"]
            case .lastPass: used = ["url", "username", "password", "name"]
            case .keePassXC: used = ["group", "title", "username", "password"]
            }
            return (used.compactMap(position(of:)).max() ?? 0) + 1
        }
    }

    private struct Record {
        let header: Header
        let fields: [String]

        subscript(name: String) -> String {
            guard let position = header.position(of: name), position < fields.count else {
                return ""
            }
            return fields[position]
        }

        func first(_ names: String...) -> String {
            names.lazy.map { self[$0] }.first { !$0.isEmpty } ?? ""
        }
    }
}

/// RFC 4180 CSV: quoted fields may hold commas, quotes ("") and line breaks.
enum CSVReader {
    struct Row: Equatable {
        /// 1-based line where the row starts.
        let line: Int
        let fields: [String]
    }

    static func rows(in text: String) -> [Row] {
        var rows: [Row] = []
        var fields: [String] = []
        var field = ""
        var inQuotes = false
        var line = 1
        var rowStart = 1
        var iterator = text.makeIterator()
        var pending: Character?

        func endRow() {
            fields.append(field)
            rows.append(Row(line: rowStart, fields: fields))
            fields = []
            field = ""
        }

        while let character = pending ?? iterator.next() {
            pending = nil
            if inQuotes {
                if character == "\"" {
                    let next = iterator.next()
                    if next == "\"" {
                        field.append("\"")
                    } else {
                        inQuotes = false
                        pending = next
                    }
                } else {
                    if character.isNewline {
                        line += 1
                    }
                    field.append(character)
                }
                continue
            }
            switch character {
            case "\"" where field.isEmpty:
                inQuotes = true
            case ",":
                fields.append(field)
                field = ""
            case _ where character.isNewline:
                endRow()
                line += 1
                rowStart = line
            default:
                field.append(character)
            }
        }
        if !field.isEmpty || !fields.isEmpty {
            endRow()
        }
        return rows
    }

    /// One CSV line, quoting every field.
    static func line(_ fields: [String]) -> String {
        fields.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",")
    }
}
