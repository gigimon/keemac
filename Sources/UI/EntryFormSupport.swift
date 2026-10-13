import Domain
import Foundation
import SwiftUI

extension VaultEntryForm {
    init(entry: VaultEntry) {
        let otpForm = entry.otp.map { otp in
            VaultOTPForm(
                secret: OTPSecretFormatter.encodeBase32(otp.secret),
                digits: otp.digits,
                period: otp.period,
                algorithm: otp.algorithm,
                storageStyle: entry.otpStorageStyle ?? .otpAuth,
                kind: otp.kind,
                counter: Int(clamping: otp.counter)
            )
        }

        // The form edits what is stored, so references and placeholders survive a save.
        self.init(
            title: entry.rawValue(VaultEntryReferences.title) ?? entry.title,
            username: entry.rawValue(VaultEntryReferences.username) ?? entry.username ?? "",
            password: entry.rawValue(VaultEntryReferences.password) ?? entry.password ?? "",
            url: entry.rawValue(VaultEntryReferences.url) ?? entry.url?.absoluteString ?? "",
            notes: entry.rawValue(VaultEntryReferences.notes) ?? entry.notes ?? "",
            tags: entry.tags,
            foregroundColorHex: entry.foregroundColorHex,
            backgroundColorHex: entry.backgroundColorHex,
            iconID: entry.iconID,
            customFields: entry.customFields.map {
                VaultCustomFieldForm(key: $0.key, value: entry.rawValue($0.key) ?? $0.value, isProtected: $0.isProtected)
            },
            attachments: entry.attachments,
            otp: otpForm,
            expiresAt: entry.expiresAt,
            checksPasswordQuality: entry.checksPasswordQuality,
            entryType: entry.entryType,
            templateName: entry.templateName,
            sshAgent: entry.sshAgent,
            autoType: entry.autoType
        )
    }
}

enum EntryFormValidation {
    static func validate(_ form: VaultEntryForm) -> String? {
        if form.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return L("Title is required.")
        }

        var keys = Set<String>()
        for field in form.customFields {
            let key = field.key.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty {
                return L("Custom field name cannot be empty.")
            }
            guard keys.insert(key.lowercased()).inserted else {
                return L("Custom field names must be unique.")
            }
        }

        if let otp = form.otp {
            if otp.secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return L("One-time password secret is required.")
            }
            if otp.kind != .steam, otp.digits < 6 || otp.digits > 9 {
                return L("TOTP digits must be between 6 and 9.")
            }
            if otp.kind == .totp, otp.period < 1 {
                return L("TOTP period must be positive.")
            }
            if otp.kind == .hotp, otp.counter < 0 {
                return L("The HOTP counter can't be negative.")
            }
        }

        if let autoType = form.autoType {
            if let sequence = autoType.sequence, let error = AutoTypeSequence.validate(sequence) {
                return L("Auto-Type: \(error.message)")
            }
            for association in autoType.associations where !association.sequence.trimmingCharacters(in: .whitespaces).isEmpty {
                if let error = AutoTypeSequence.validate(association.sequence) {
                    return L("Auto-Type: \(error.message)")
                }
            }
        }

        return nil
    }

    static func parseTags(_ text: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for piece in text.split(whereSeparator: { $0 == "," || $0 == ";" }) {
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else {
                continue
            }
            result.append(trimmed)
        }
        return result
    }
}

enum OTPInputParser {
    /// Accepts either a raw secret or an `otpauth://` URI (TOTP, HOTP or Steam) and fills the form accordingly.
    static func apply(_ input: String, to form: VaultOTPForm?) -> VaultOTPForm? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        guard let parsed = VaultOTPURI.parse(trimmed, base: form) else {
            var result = form ?? VaultOTPForm(secret: "")
            result.secret = trimmed
            return result
        }
        return parsed
    }
}

enum GroupPathFormatter {
    /// Group paths are KeePass breadcrumbs that start with the root group ("Root.Work.Servers").
    static func display(_ path: String, rootPath: String) -> String {
        let relative = relativeComponents(path, rootPath: rootPath)
        guard !relative.isEmpty else {
            return title(of: rootPath)
        }
        return relative.joined(separator: " › ")
    }

    static func relativeComponents(_ path: String, rootPath: String) -> [String] {
        if path.isEmpty || path == rootPath {
            return []
        }
        if !rootPath.isEmpty, path.hasPrefix(rootPath + ".") {
            return path.dropFirst(rootPath.count + 1).split(separator: ".").map(String.init)
        }
        return path.split(separator: ".").map(String.init)
    }

    static func title(of path: String) -> String {
        path.split(separator: ".").last.map(String.init) ?? path
    }

    static func depth(of path: String, rootPath: String) -> Int {
        max(relativeComponents(path, rootPath: rootPath).count - 1, 0)
    }
}

enum RelativeDateFormatter {
    static func modified(_ date: Date?, now: Date = .now) -> String {
        guard let date else {
            return L("unknown")
        }
        let hours = Int(now.timeIntervalSince(date) / 3600)
        if hours < 1 {
            return L("just now")
        }
        if hours < 24 {
            return L("\(hours) hours ago")
        }
        if hours < 48 {
            return L("yesterday")
        }
        return L("\(Int((Double(hours) / 24).rounded())) days ago")
    }

    static func absolute(_ date: Date?) -> String {
        guard let date else {
            return L("unknown")
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

