import AppKit
import Data
import Domain
import SSHAgent
import SwiftUI

/// Settings → SSH Agent → Import Keys from ~/.ssh: keys found there become SSH Key entries of the main database.
struct SSHImportSheet: View {
    let viewModel: AppViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [SSHKeyFileCandidate] = SSHDirectoryScanner.scan()
    @State private var selected: Set<String> = []
    @State private var groupPath = ""
    @State private var leavesFiles = true
    @State private var isAskingPassphrases = false
    @State private var passphrases: [String: String] = [:]
    @State private var unlocked: [String: String] = [:]
    @State private var wrong: Set<String> = []
    @State private var isImporting = false
    @State private var failure: String?

    private var chosen: [SSHKeyFileCandidate] {
        candidates.filter { selected.contains($0.id) }
    }

    private var encrypted: [SSHKeyFileCandidate] {
        chosen.filter(\.info.isEncrypted)
    }

    private var vault: LoadedVault? {
        if case .loaded(let vault) = viewModel.loadState {
            return vault
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "key.horizontal.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(VaultEntryType.sshKey.tileColor))
                VStack(alignment: .leading, spacing: 1) {
                    Text(isAskingPassphrases ? L("Enter Passphrases") : L("Import from ~/.ssh"))
                        .font(.system(size: 15, weight: .bold))
                    Text(isAskingPassphrases ? L("\(encrypted.count) keys are encrypted") : L("\(candidates.count) private keys found in ~/.ssh"))
                        .font(.system(size: 11))
                        .foregroundStyle(KM.textSecondary)
                }
            }

            if isAskingPassphrases {
                passphraseList
            } else {
                keyList
                optionRows
            }

            if let failure {
                Text(failure)
                    .font(.system(size: 11))
                    .foregroundStyle(KM.danger)
            }

            HStack(spacing: 8) {
                if isAskingPassphrases {
                    Button(L("Back")) { isAskingPassphrases = false }
                        .buttonStyle(KMButtonStyle(kind: .secondary, height: 30, fontWeight: .regular))
                }
                Spacer()
                Button(L("Cancel")) { dismiss() }
                    .buttonStyle(KMButtonStyle(kind: .secondary, height: 30, fontWeight: .regular))
                    .keyboardShortcut(.cancelAction)
                Button(action: next) {
                    HStack(spacing: 6) {
                        if isImporting {
                            ProgressView().controlSize(.mini).tint(.white)
                        }
                        Text(L("Import \(chosen.count) Keys"))
                    }
                }
                .buttonStyle(KMButtonStyle(kind: .primary, height: 30, horizontalPadding: 18, fontWeight: .semibold))
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty || isImporting || (isAskingPassphrases && encrypted.contains { unlocked[$0.id] == nil }))
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .frame(width: 560)
        .background(KM.sheetBackground)
        .onAppear {
            selected = Set(candidates.map(\.id))
        }
    }

    // MARK: Step 1

    private var keyList: some View {
        ScrollView {
            VStack(spacing: 0) {
                if candidates.isEmpty {
                    Text(L("No private keys in ~/.ssh"))
                        .font(.system(size: 12))
                        .foregroundStyle(KM.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                }
                ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                    HStack(alignment: .top, spacing: 10) {
                        KMCheckbox(title: "", isOn: Binding(
                            get: { selected.contains(candidate.id) },
                            set: { isOn in
                                if isOn { selected.insert(candidate.id) } else { selected.remove(candidate.id) }
                            }
                        ))
                        .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Image(systemName: "key.horizontal").font(.system(size: 11)).foregroundStyle(KM.textSecondary)
                                Text(candidate.url.lastPathComponent).font(.system(size: 13, weight: .medium))
                                if candidate.info.isEncrypted {
                                    Label(L("encrypted"), systemImage: "lock.fill")
                                        .font(.system(size: 10))
                                        .foregroundStyle(KM.textSecondary)
                                }
                            }
                            Text(meta(candidate))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(KM.textSecondary)
                            if !candidate.hosts.isEmpty {
                                FlowLayout(spacing: 4) {
                                    ForEach(candidate.hosts, id: \.self) { host in
                                        Text(host)
                                            .font(.system(size: 11, design: .monospaced))
                                            .padding(.horizontal, 7)
                                            .frame(height: 20)
                                            .background(Capsule(style: .continuous).fill(KM.subtleFill))
                                    }
                                }
                                .help(L("Hosts in ~/.ssh/config"))
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .overlay(alignment: .top) {
                        if index > 0 {
                            Rectangle().fill(KM.hairline).frame(height: 0.5)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: 280)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(KM.insetFill))
    }

    private func meta(_ candidate: SSHKeyFileCandidate) -> String {
        guard let publicKey = candidate.info.publicKey else { return "PEM" }
        return "\(publicKey.algorithm.displayName) · \(publicKey.fingerprint.prefix(20))…"
    }

    private var optionRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text(L("Save to"))
                    .font(.system(size: 12))
                    .foregroundStyle(KM.textSecondary)
                Picker("", selection: $groupPath) {
                    Text(rootTitle).tag("")
                    ForEach(groupOptions) { option in
                        Text(String(repeating: "    ", count: option.depth + 1) + option.title).tag(option.path)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            KMCheckbox(title: L("Leave the files in ~/.ssh"), isOn: $leavesFiles)
            Text(L("KeeMac keeps its own copy in the database. Turn off to delete the originals after import."))
                .font(.system(size: 11))
                .foregroundStyle(KM.textSecondary)
        }
    }

    private var rootPath: String {
        vault?.groups.first { !$0.path.contains(".") && DatabaseScope.key(of: $0.path) == nil }?.path ?? ""
    }

    private var rootTitle: String {
        GroupPathFormatter.title(of: rootPath)
    }

    private var groupOptions: [GroupOption] {
        (vault?.groups ?? [])
            .filter { !$0.isTrash && $0.path != rootPath && DatabaseScope.key(of: $0.path) == nil }
            .sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
            .map { GroupOption(path: $0.path, title: $0.title, depth: GroupPathFormatter.depth(of: $0.path, rootPath: rootPath)) }
    }

    // MARK: Step 2

    private var passphraseList: some View {
        VStack(spacing: 0) {
            ForEach(Array(encrypted.enumerated()), id: \.element.id) { index, candidate in
                HStack(spacing: 10) {
                    Text(candidate.url.lastPathComponent)
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 130, alignment: .leading)
                    if unlocked[candidate.id] != nil {
                        Label(L("Passphrase saved"), systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(KM.success)
                        Spacer()
                    } else {
                        SecureField(L("Passphrase"), text: Binding(
                            get: { passphrases[candidate.id] ?? "" },
                            set: { passphrases[candidate.id] = $0; wrong.remove(candidate.id) }
                        ))
                        .onSubmit { unlock(candidate) }
                        .kmField(invalid: wrong.contains(candidate.id), height: 28, background: KM.raisedFieldBackground)
                        Button(L("Unlock")) { unlock(candidate) }
                            .buttonStyle(KMButtonStyle(kind: .raised, height: 26, horizontalPadding: 10, fontWeight: .regular, fontSize: 12))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .overlay(alignment: .top) {
                    if index > 0 {
                        Rectangle().fill(KM.hairline).frame(height: 0.5)
                    }
                }
                if wrong.contains(candidate.id) {
                    Label(L("Wrong passphrase"), systemImage: "exclamationmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(KM.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 152)
                        .padding(.bottom, 6)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(KM.insetFill))
    }

    private func unlock(_ candidate: SSHKeyFileCandidate) {
        let passphrase = passphrases[candidate.id] ?? ""
        guard !passphrase.isEmpty else { return }
        if (try? SSHKeyReader.read(candidate.data, passphrase: passphrase)) != nil {
            unlocked[candidate.id] = passphrase
        } else {
            wrong.insert(candidate.id)
        }
    }

    // MARK: Import

    private func next() {
        if !isAskingPassphrases, !encrypted.isEmpty {
            isAskingPassphrases = true
            return
        }
        isImporting = true
        failure = nil
        let supportsTypes = vault?.summary.supportsEntryTypes ?? false
        let target = groupPath.isEmpty ? nil : groupPath
        let keys = chosen
        Task {
            var imported = 0
            for candidate in keys {
                let passphrase = unlocked[candidate.id] ?? ""
                let key = try? SSHKeyReader.read(candidate.data, passphrase: passphrase.isEmpty ? nil : passphrase)
                let comment = key?.publicKey.comment ?? ""
                var form = VaultEntryForm(title: candidate.url.lastPathComponent)
                if comment.contains("@"), let user = comment.split(separator: "@").first {
                    form.username = String(user)
                }
                form.password = passphrase
                form.attachments = [VaultAttachment(name: candidate.url.lastPathComponent, data: candidate.data)]
                form.entryType = supportsTypes ? .sshKey : .login
                form.sshAgent = VaultSSHAgentSettings(
                    keyAttachmentName: candidate.url.lastPathComponent,
                    hosts: candidate.hosts.map { VaultSSHHost(pattern: $0) }
                )
                do {
                    try await viewModel.createEntry(inGroupPath: target, form: form)
                    imported += 1
                    if !leavesFiles {
                        try? FileManager.default.removeItem(at: candidate.url)
                        try? FileManager.default.removeItem(at: candidate.url.appendingPathExtension("pub"))
                    }
                } catch {
                    failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
            isImporting = false
            if failure == nil {
                CopyFeedbackCenter.shared.show(L("\(imported) keys imported to \(GroupPathFormatter.title(of: target ?? rootPath))"), duration: 2.4)
                dismiss()
            }
        }
    }
}
