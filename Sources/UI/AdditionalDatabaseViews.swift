import AppKit
import Data
import Domain
import SwiftUI
import UniformTypeIdentifiers

/// What the browser needs to show additional databases and act on them.
public struct AdditionalDatabasesContext {
    public var databases: [AdditionalDatabase] = []
    /// Root group of each unlocked additional database, in the browser's paths.
    public var rootPaths: [String: String] = [:]
    public var supportsEntryTypes: [String: Bool] = [:]
    public var usesRecycleBin: [String: Bool] = [:]
    public var onAdd: @MainActor (URL, String, URL?) async throws -> Void = { _, _, _ in }
    public var onUnlock: @MainActor (String, String, URL?) async throws -> Void = { _, _, _ in }
    public var onLock: @MainActor (String) -> Void = { _ in }
    public var onRemove: @MainActor (String) -> Void = { _ in }
    public var onLocate: @MainActor (String, URL) throws -> Void = { _, _ in }
    public var onActiveDatabaseChanged: @MainActor (String?) -> Void = { _ in }
    public var onPrepareTransfer: @MainActor ([UUID], String?, String?, Bool) async throws -> PreparedTransfer = { _, _, _, _ in
        throw AdditionalDatabaseError.notUnlocked
    }
    public var onCommitTransfer: @MainActor (PreparedTransfer, [UUID: VaultTransferDecision]) async throws -> Int = { _, _ in 0 }
    public var onUndoTransfer: @MainActor () async -> Void = {}

    public init() {}

    var unlockedKeys: Set<String> {
        Set(rootPaths.keys)
    }

    func database(_ key: String) -> AdditionalDatabase? {
        databases.first { $0.id == key }
    }
}

// MARK: - Unlock

struct AdditionalUnlockRequest: Identifiable {
    enum Kind {
        /// A database from the list.
        case listed(key: String)
        /// A file just picked with "Add Additional Database…"; it joins the list once it unlocks.
        case new(URL)
    }

    let id = UUID()
    let kind: Kind
    let fileName: String
    let path: String
    let keyFileURL: URL?
}

/// Password (and key file) for an additional database. Touch ID is never offered here.
struct AdditionalUnlockSheet: View {
    let request: AdditionalUnlockRequest
    let onUnlock: (_ password: String, _ keyFileURL: URL?) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var revealsPassword = false
    @State private var keyFileURL: URL?
    @State private var isUnlocking = false
    @State private var isWrong = false
    @State private var failure: String?
    @FocusState private var isPasswordFocused: Bool

    init(request: AdditionalUnlockRequest, onUnlock: @escaping (_ password: String, _ keyFileURL: URL?) async throws -> Void) {
        self.request = request
        self.onUnlock = onUnlock
        _keyFileURL = State(initialValue: request.keyFileURL)
    }

    private var canUnlock: Bool {
        (!password.isEmpty || keyFileURL != nil) && !isUnlocking
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "cylinder.split.1x2")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(KM.accent)
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(KM.accent.opacity(0.14)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("Unlock \(request.fileName)"))
                        .font(.system(size: 15, weight: .bold))
                        .lineLimit(1)
                    Text(request.path)
                        .font(.system(size: 11))
                        .foregroundStyle(KM.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(request.path)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 0) {
                    Group {
                        if revealsPassword {
                            TextField(L("Master password"), text: $password)
                        } else {
                            SecureField(L("Master password"), text: $password)
                        }
                    }
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($isPasswordFocused)
                    .onSubmit(unlock)
                    .onChange(of: password) {
                        isWrong = false
                    }
                    Button {
                        revealsPassword.toggle()
                    } label: {
                        Image(systemName: revealsPassword ? "eye.slash" : "eye")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(KMIconButtonStyle(size: 22, cornerRadius: 5))
                    .iconHelp(revealsPassword ? L("Hide password") : L("Show password"))
                }
                .kmField(focused: isPasswordFocused, invalid: isWrong, background: KM.raisedFieldBackground)

                if isWrong {
                    Label(L("Wrong password or key file"), systemImage: "exclamationmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(KM.danger)
                } else if let failure {
                    Label(failure, systemImage: "exclamationmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(KM.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    Text(L("Key file"))
                        .font(.system(size: 12))
                        .foregroundStyle(KM.textSecondary)
                    if let keyFileURL {
                        Image(systemName: "key.horizontal")
                            .font(.system(size: 11))
                            .foregroundStyle(KM.textSecondary)
                        Text(keyFileURL.lastPathComponent)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button {
                            self.keyFileURL = nil
                            isWrong = false
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .buttonStyle(KMIconButtonStyle(size: 16, cornerRadius: 8))
                        .iconHelp(L("Remove key file"))
                    } else {
                        Text(L("None"))
                            .font(.system(size: 12))
                            .foregroundStyle(KM.textTertiary)
                    }
                    Spacer(minLength: 0)
                    Button(L("Choose…"), action: chooseKeyFile)
                        .buttonStyle(KMButtonStyle(kind: .raised, height: 22, horizontalPadding: 10, fontWeight: .regular, fontSize: 12))
                }
                .padding(.top, 6)
            }
            .padding(.top, 18)
            .disabled(isUnlocking)
            .opacity(isUnlocking ? 0.55 : 1)

            HStack(spacing: 8) {
                Spacer()
                Button(L("Cancel")) {
                    dismiss()
                }
                .buttonStyle(KMButtonStyle(kind: .secondary, height: 30, fontWeight: .regular))
                .keyboardShortcut(.cancelAction)
                .disabled(isUnlocking)

                Button(action: unlock) {
                    HStack(spacing: 6) {
                        if isUnlocking {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(.white)
                        }
                        Text(isUnlocking ? L("Unlocking…") : L("Unlock"))
                    }
                }
                .buttonStyle(KMButtonStyle(kind: .primary, height: 30, horizontalPadding: 18, fontWeight: .semibold))
                .keyboardShortcut(.defaultAction)
                .disabled(!canUnlock)
            }
            .padding(.top, 20)
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 18)
        .frame(width: 420)
        .background(KM.sheetBackground)
        .onAppear {
            isPasswordFocused = true
        }
    }

    private func chooseKeyFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = L("Choose the key file for \(request.fileName)")
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        keyFileURL = url
        isWrong = false
    }

    private func unlock() {
        guard canUnlock else {
            return
        }
        isUnlocking = true
        isWrong = false
        failure = nil
        Task {
            do {
                try await onUnlock(password, keyFileURL)
                dismiss()
            } catch VaultError.invalidPassword {
                isWrong = true
                isPasswordFocused = true
                DispatchQueue.main.async {
                    NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                }
            } catch {
                failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            isUnlocking = false
        }
    }
}

// MARK: - Transfer conflicts

/// A move or copy waiting for the user's answers to its conflicts.
struct TransferFlow: Identifiable {
    let id = UUID()
    let transfer: PreparedTransfer
    let sourceName: String
    let targetName: String
    var index = 0
    var decisions: [UUID: VaultTransferDecision] = [:]
}

/// "“GitHub” already exists in Work": both versions side by side, the newer one ringed in green.
struct TransferConflictSheet: View {
    @Binding var flow: TransferFlow?
    let onFinish: (TransferFlow) -> Void

    @State private var appliesToAll = false

    var body: some View {
        if let flow, flow.transfer.conflicts.indices.contains(flow.index) {
            let conflict = flow.transfer.conflicts[flow.index]
            let remaining = flow.transfer.conflicts.count - flow.index
            let incomingIsNewer = (conflict.incomingModifiedAt ?? .distantPast) > (conflict.existingModifiedAt ?? .distantPast)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(KM.warning)
                        .frame(width: 40, height: 40)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(KM.warning.opacity(0.14)))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("“\(conflict.title)” already exists in \(flow.targetName)"))
                            .font(.system(size: 15, weight: .bold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(flow.transfer.isCopy
                             ? L("The database you’re copying to has this entry. Replacing keeps the current version in its history.")
                             : L("The database you’re moving to has this entry. Replacing keeps the current version in its history."))
                            .font(.system(size: 12))
                            .foregroundStyle(KM.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if flow.transfer.conflicts.count > 1 {
                        Text(L("\(flow.index + 1) of \(flow.transfer.conflicts.count)"))
                            .font(.system(size: 11))
                            .foregroundStyle(KM.textTertiary)
                    }
                }

                HStack(spacing: 10) {
                    side(
                        label: flow.transfer.isCopy ? L("Copying from \(flow.sourceName)") : L("Moving from \(flow.sourceName)"),
                        symbol: "arrow.right",
                        title: conflict.title,
                        username: conflict.username,
                        modified: conflict.incomingModifiedAt,
                        isNewer: incomingIsNewer
                    )
                    side(
                        label: L("In \(flow.targetName)"),
                        symbol: "cylinder.split.1x2",
                        title: conflict.existingTitle,
                        username: conflict.existingUsername,
                        modified: conflict.existingModifiedAt,
                        isNewer: !incomingIsNewer && conflict.incomingModifiedAt != conflict.existingModifiedAt
                    )
                }
                .padding(.top, 16)

                if flow.transfer.linkedFieldCount > 0 {
                    Label(linkedFieldsText(flow.transfer.linkedFieldCount), systemImage: "link")
                        .font(.system(size: 11))
                        .foregroundStyle(KM.textSecondary)
                        .padding(.top, 12)
                }

                HStack(spacing: 8) {
                    if remaining > 1 {
                        KMCheckbox(title: L("Apply to all \(remaining) conflicts"), isOn: $appliesToAll)
                    }
                    Spacer()
                    Button(L("Skip")) { decide(.skip) }
                        .buttonStyle(KMButtonStyle(kind: .secondary, height: 30, fontWeight: .regular))
                        .keyboardShortcut(.cancelAction)
                    Button(L("Keep Both")) { decide(.keepBoth) }
                        .buttonStyle(KMButtonStyle(kind: .secondary, height: 30, fontWeight: .regular))
                    Button(L("Replace")) { decide(.replace) }
                        .buttonStyle(KMButtonStyle(kind: .primary, height: 30, horizontalPadding: 18, fontWeight: .semibold))
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 20)
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 18)
            .frame(width: 500)
            .background(KM.sheetBackground)
        }
    }

    private func side(label: String, symbol: String, title: String, username: String, modified: Date?, isNewer: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(label, systemImage: symbol)
                .font(.system(size: 11))
                .foregroundStyle(KM.textSecondary)
                .lineLimit(1)
            HStack(spacing: 10) {
                LetterTile(title: title, size: 30, cornerRadius: 8, fontSize: 13)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title.isEmpty ? L("Untitled") : title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(username.isEmpty ? "—" : username)
                        .font(.system(size: 11))
                        .foregroundStyle(KM.textSecondary)
                        .lineLimit(1)
                }
            }
            HStack(spacing: 4) {
                Text(L("Modified \(RelativeDateFormatter.modified(modified))"))
                if isNewer {
                    Text(L("Newer"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(KM.success)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(KM.textTertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(KM.insetFill))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isNewer ? KM.success.opacity(0.7) : KM.hairline, lineWidth: isNewer ? 1.5 : 0.5)
        )
    }

    private func decide(_ decision: VaultTransferDecision) {
        guard var current = flow else {
            return
        }
        let conflicts = current.transfer.conflicts
        let last = appliesToAll ? conflicts.count : current.index + 1
        for index in current.index..<last {
            current.decisions[conflicts[index].id] = decision
        }
        current.index = last
        appliesToAll = false
        if current.index >= conflicts.count {
            flow = nil
            onFinish(current)
        } else {
            flow = current
        }
    }
}

func linkedFieldsText(_ count: Int) -> String {
    L("\(count) linked fields will be copied as plain values. Links only work inside one database.")
}

// MARK: - Settings of an additional database

/// Read-only: an additional database's encryption and master key are changed by opening it as the main database.
struct AdditionalDatabaseInfoSheet: View {
    let database: AdditionalDatabase
    let mainName: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "cylinder.split.1x2")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(KM.accent)
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(KM.accent.opacity(0.14)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(database.fileName)
                        .font(.system(size: 15, weight: .bold))
                    Text(L("Additional database. Opens alongside \(mainName) and locks with it."))
                        .font(.system(size: 11))
                        .foregroundStyle(KM.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(spacing: 0) {
                row(L("Location"), database.path, isFirst: true)
                row(L("Key file"), database.keyFileURL?.lastPathComponent ?? L("None"))
                row(L("Format"), database.url.flatMap { KDBXHeaderReader.read(from: $0)?.summary } ?? "—")
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(KM.insetFill))
            .padding(.top, 18)

            HStack {
                Spacer()
                Button(L("Done")) {
                    dismiss()
                }
                .buttonStyle(KMButtonStyle(kind: .primary, height: 30, horizontalPadding: 18, fontWeight: .semibold))
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 20)
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 18)
        .frame(width: 440)
        .background(KM.sheetBackground)
    }

    private func row(_ label: String, _ value: String, isFirst: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(KM.textSecondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .overlay(alignment: .top) {
            if !isFirst {
                Rectangle().fill(KM.hairline).frame(height: 0.5).padding(.horizontal, 14)
            }
        }
    }
}

/// Picks a .kdbx file for "Add Additional Database…" or "Locate…".
@MainActor
func chooseDatabaseFile(message: String) -> URL? {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    if let kdbx = UTType(filenameExtension: "kdbx") {
        panel.allowedContentTypes = [kdbx]
    }
    panel.message = message
    return panel.runModal() == .OK ? panel.url : nil
}
