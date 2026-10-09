import AppKit
import Domain
import SSHAgent
import SwiftUI
import UniformTypeIdentifiers

extension VaultSSHConfirmation {
    var title: String {
        switch self {
        case .everyTime: return L("Every time")
        case .oncePerUnlock: return L("Once per unlock")
        case .never: return L("ssh.confirmation.never", default: "Never")
        }
    }
}

/// A private key being added in the SSH Key sheet: what was read from it and whether its passphrase is known.
struct SSHKeyDraft: Equatable {
    enum PassphraseState: Equatable {
        case notNeeded
        case needed
        case wrong
        case saved
    }

    var attachment: VaultAttachment?
    var publicKey: SSHPublicKey?
    var passphraseState: PassphraseState = .notNeeded
    /// The passphrase that opened the key; it becomes the entry's password.
    var passphrase = ""
    /// The file that wasn't a key, for "This file isn't a private SSH key".
    var rejectedName: String?

    var isReady: Bool {
        attachment != nil && passphraseState != .needed && passphraseState != .wrong
    }

    /// Reads a key file or pasted text. Encrypted OpenSSH keys still show their public part.
    static func reading(_ data: Data, name: String, passphrase: String = "") -> SSHKeyDraft {
        var draft = SSHKeyDraft()
        guard let info = try? SSHKeyReader.inspect(data) else {
            draft.rejectedName = name
            return draft
        }
        draft.attachment = VaultAttachment(name: name, data: data)
        draft.publicKey = info.publicKey
        if info.isEncrypted {
            draft.passphraseState = .needed
            if !passphrase.isEmpty {
                draft.unlock(with: passphrase)
            }
        } else if let key = try? SSHKeyReader.read(data, passphrase: nil) {
            draft.publicKey = key.publicKey
        }
        return draft
    }

    mutating func unlock(with passphrase: String) {
        guard let attachment else { return }
        do {
            let key = try SSHKeyReader.read(attachment.data, passphrase: passphrase)
            publicKey = key.publicKey
            self.passphrase = passphrase
            passphraseState = .saved
        } catch {
            passphraseState = .wrong
        }
    }

    /// A file name for pasted or generated keys: id_ed25519, id_rsa, id_ecdsa.
    static func fileName(for algorithm: SSHKeyAlgorithm?) -> String {
        switch algorithm {
        case .rsa: return "id_rsa"
        case .ecdsa: return "id_ecdsa"
        default: return "id_ed25519"
        }
    }
}

/// `anna@Annas-MacBook-Pro.local`: the same user and host name `ssh-keygen` puts in its default comment.
func defaultSSHKeyComment() -> String {
    var buffer = [CChar](repeating: 0, count: 256)
    let host = gethostname(&buffer, buffer.count) == 0 ? String(cString: buffer) : ProcessInfo.processInfo.hostName
    return "\(NSUserName())@\(host)"
}

/// Drop, choose, paste or generate a private key; then its card with fingerprint and public key.
struct SSHKeyPicker: View {
    @Binding var draft: SSHKeyDraft
    /// Fills the title and username from the key's comment once a key is in.
    var onKeyAdded: (SSHPublicKey?) -> Void = { _ in }

    @State private var isDropTargeted = false
    @State private var isGenerating = false
    @State private var generateKind: SSHKeyKind = .ed25519
    @State private var generateComment = defaultSSHKeyComment()
    @State private var generatePassphrase = ""
    @State private var isBusy = false
    @State private var passphraseInput = ""
    @FocusState private var isPassphraseFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isGenerating {
                generatePanel
            } else if let rejected = draft.rejectedName {
                rejectedBlock(rejected)
            } else if draft.attachment != nil {
                keyCard
            } else {
                dropZone
            }
        }
    }

    // MARK: Empty

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "key.horizontal")
                .font(.system(size: 18))
                .foregroundStyle(KM.accent)
            Text(L("Drop a private key here"))
                .font(.system(size: 13, weight: .medium))
            Text(L("Usually in ~/.ssh — id_ed25519, id_rsa…"))
                .font(.system(size: 11))
                .foregroundStyle(KM.textSecondary)
            HStack(spacing: 8) {
                Button(L("Choose File…"), action: chooseFile)
                    .buttonStyle(KMButtonStyle(kind: .raised, height: 24, horizontalPadding: 12, fontWeight: .regular, fontSize: 12))
                Button(L("Paste Key"), action: paste)
                    .buttonStyle(KMButtonStyle(kind: .raised, height: 24, horizontalPadding: 12, fontWeight: .regular, fontSize: 12))
                Button(L("Generate New Key…")) {
                    isGenerating = true
                }
                .buttonStyle(KMButtonStyle(kind: .secondary, height: 24, horizontalPadding: 12, fontWeight: .regular, fontSize: 12))
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isDropTargeted ? KM.accent.opacity(0.08) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isDropTargeted ? KM.accent : KM.fieldBorder, style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
        )
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: drop)
    }

    private func rejectedBlock(_ name: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(KM.danger)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("This file isn’t a private SSH key"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(KM.danger)
                Text(L("\(name) · Use an OpenSSH or PEM private key."))
                    .font(.system(size: 11))
            }
            Spacer(minLength: 0)
            Button(L("Choose Another…"), action: chooseFile)
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(KM.accent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(KM.danger.opacity(0.09)))
    }

    // MARK: Generate

    private var generatePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Generate New Key"))
                .font(.system(size: 12, weight: .semibold))
            HStack(spacing: 10) {
                Text(L("Type"))
                    .font(.system(size: 12))
                    .foregroundStyle(KM.textSecondary)
                    .frame(width: 74, alignment: .leading)
                KMSegmentedControl(
                    options: [(SSHKeyKind.ed25519, "Ed25519"), (.rsa4096, "RSA 4096"), (.ecdsaP256, "ECDSA P-256")],
                    selection: $generateKind
                )
            }
            Text(generateHint)
                .font(.system(size: 11))
                .foregroundStyle(KM.textSecondary)
                .padding(.leading, 84)
            HStack(spacing: 10) {
                Text(L("Comment"))
                    .font(.system(size: 12))
                    .foregroundStyle(KM.textSecondary)
                    .frame(width: 74, alignment: .leading)
                TextField("", text: $generateComment)
                    .kmField(height: 28, background: KM.raisedFieldBackground)
            }
            HStack(spacing: 10) {
                Text(L("Passphrase"))
                    .font(.system(size: 12))
                    .foregroundStyle(KM.textSecondary)
                    .frame(width: 74, alignment: .leading)
                SecureField(L("Optional"), text: $generatePassphrase)
                    .kmField(height: 28, background: KM.raisedFieldBackground)
            }
            Text(L("The passphrase is saved as this entry’s password."))
                .font(.system(size: 11))
                .foregroundStyle(KM.textSecondary)
                .padding(.leading, 84)
            HStack(spacing: 8) {
                Spacer()
                Button(L("Cancel")) {
                    isGenerating = false
                }
                .buttonStyle(KMButtonStyle(kind: .secondary, height: 26, fontWeight: .regular, fontSize: 12))
                .disabled(isBusy)
                Button(action: generate) {
                    HStack(spacing: 6) {
                        if isBusy {
                            ProgressView().controlSize(.mini).tint(.white)
                        }
                        Text(isBusy ? L("Generating…") : L("Generate"))
                    }
                }
                .buttonStyle(KMButtonStyle(kind: .primary, height: 26, horizontalPadding: 14, fontWeight: .semibold, fontSize: 12))
                .disabled(isBusy)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(KM.insetFill))
    }

    private var generateHint: String {
        switch generateKind {
        case .ed25519: return L("Recommended. Short, fast and supported by most servers.")
        case .rsa4096: return L("For older servers without Ed25519 support.")
        case .ecdsaP256: return L("For systems that require NIST curves.")
        }
    }

    private func generate() {
        isBusy = true
        let kind = generateKind
        let comment = generateComment.trimmingCharacters(in: .whitespaces)
        let passphrase = generatePassphrase
        Task {
            let result = await Task.detached { () -> Data? in
                guard let key = try? SSHPrivateKey.generate(kind, comment: comment) else { return nil }
                return try? key.openSSHText(passphrase: passphrase.isEmpty ? nil : passphrase)
            }.value
            isBusy = false
            guard let result else { return }
            let name = SSHKeyDraft.fileName(for: kind == .rsa4096 ? .rsa(bits: 4096) : kind == .ecdsaP256 ? .ecdsa(.p256) : .ed25519)
            draft = SSHKeyDraft.reading(result, name: name, passphrase: passphrase)
            isGenerating = false
            onKeyAdded(draft.publicKey)
        }
    }

    // MARK: Card

    private var keyCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "key.horizontal.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(VaultEntryType.sshKey.tileColor))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(draft.publicKey?.algorithm.displayName ?? L("SSH key"))
                            .font(.system(size: 13, weight: .semibold))
                        Text("\(draft.attachment?.name ?? "") · \(draft.attachment.map(AttachmentInfo.size) ?? "")")
                            .font(.system(size: 11))
                            .foregroundStyle(KM.textSecondary)
                    }
                    if let fingerprint = draft.publicKey?.fingerprint {
                        Text(fingerprint)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(KM.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
                Spacer(minLength: 0)
                Button {
                    draft = SSHKeyDraft()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(KMIconButtonStyle(size: 24, cornerRadius: 6))
                .iconHelp(L("Remove"))
            }
            .padding(10)

            if let publicKey = draft.publicKey {
                if !publicKey.comment.isEmpty {
                    cardRow(L("Comment")) {
                        Text(publicKey.comment).font(.system(size: 12))
                    }
                }
                cardRow(L("Public key")) {
                    HStack(spacing: 6) {
                        Text(publicKey.authorizedKeysLine)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button {
                            copyPublicKey(publicKey)
                        } label: {
                            Image(systemName: "doc.on.doc").font(.system(size: 11))
                        }
                        .buttonStyle(KMIconButtonStyle(size: 22, cornerRadius: 5))
                        .iconHelp(L("Copy Public Key"))
                    }
                }
            }

            passphraseRows

            if draft.publicKey != nil, draft.passphraseState != .needed, draft.passphraseState != .wrong {
                HStack(spacing: 8) {
                    Button {
                        if let publicKey = draft.publicKey {
                            copyPublicKey(publicKey)
                        }
                    } label: {
                        Label(L("Copy Public Key"), systemImage: "doc.on.doc")
                    }
                    .buttonStyle(KMButtonStyle(kind: .raised, height: 24, horizontalPadding: 10, fontWeight: .regular, fontSize: 12))
                    Text(L("Add it to the server’s authorized_keys or to GitHub."))
                        .font(.system(size: 11))
                        .foregroundStyle(KM.textSecondary)
                }
                .padding(10)
                .overlay(alignment: .top) {
                    Rectangle().fill(KM.hairline).frame(height: 0.5)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(KM.raisedFieldBackground))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(KM.softBorder, lineWidth: 0.5))
    }

    @ViewBuilder
    private var passphraseRows: some View {
        switch draft.passphraseState {
        case .needed, .wrong:
            VStack(alignment: .leading, spacing: 6) {
                Label(L("Encrypted — enter its passphrase"), systemImage: "lock.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(KM.textSecondary)
                HStack(spacing: 8) {
                    SecureField(L("Passphrase"), text: $passphraseInput)
                        .focused($isPassphraseFocused)
                        .onSubmit(unlock)
                        .kmField(focused: isPassphraseFocused, invalid: draft.passphraseState == .wrong, height: 28, background: KM.fieldBackground)
                    Button(L("Unlock"), action: unlock)
                        .buttonStyle(KMButtonStyle(kind: .primary, height: 26, horizontalPadding: 12, fontWeight: .semibold, fontSize: 12))
                        .disabled(passphraseInput.isEmpty)
                }
                if draft.passphraseState == .wrong {
                    Label(L("Wrong passphrase"), systemImage: "exclamationmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(KM.danger)
                }
            }
            .padding(10)
            .overlay(alignment: .top) {
                Rectangle().fill(KM.hairline).frame(height: 0.5)
            }
            .onAppear {
                isPassphraseFocused = true
            }
        case .saved:
            Label(L("Passphrase saved as this entry’s password"), systemImage: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(KM.success)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .overlay(alignment: .top) {
                    Rectangle().fill(KM.hairline).frame(height: 0.5)
                }
        case .notNeeded:
            EmptyView()
        }
    }

    private func cardRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(KM.textSecondary)
                .frame(width: 70, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .overlay(alignment: .top) {
            Rectangle().fill(KM.hairline).frame(height: 0.5)
        }
    }

    // MARK: Actions

    private func unlock() {
        guard !passphraseInput.isEmpty else { return }
        draft.unlock(with: passphraseInput)
        if draft.passphraseState == .saved {
            passphraseInput = ""
            onKeyAdded(draft.publicKey)
        } else {
            isPassphraseFocused = true
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.message = L("Choose a private SSH key")
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        load(data, name: url.lastPathComponent)
    }

    private func paste() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        let data = Data(text.utf8)
        let name = SSHKeyDraft.fileName(for: (try? SSHKeyReader.inspect(data))?.publicKey?.algorithm)
        load(data, name: name)
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, let data = try? Data(contentsOf: url) else { return }
            Task { @MainActor in
                load(data, name: url.lastPathComponent)
            }
        }
        return true
    }

    private func load(_ data: Data, name: String) {
        draft = SSHKeyDraft.reading(data, name: name)
        if draft.attachment != nil, draft.passphraseState == .notNeeded {
            onKeyAdded(draft.publicKey)
        }
    }

    private func copyPublicKey(_ publicKey: SSHPublicKey) {
        SensitiveClipboard.shared.copyPlainText(publicKey.authorizedKeysLine, label: L("Public key"))
    }
}

/// Hosts a key is for: chips, learned ones marked, and a field to add more.
struct SSHHostsField: View {
    @Binding var hosts: [VaultSSHHost]
    @State private var input = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FlowLayout(spacing: 6) {
                ForEach(hosts, id: \.pattern) { host in
                    HStack(spacing: 4) {
                        Text(host.pattern)
                            .font(.system(size: 12, design: .monospaced))
                        if host.isLearned {
                            Text(L("learned"))
                                .font(.system(size: 10))
                                .foregroundStyle(KM.accent)
                        }
                        Button {
                            hosts.removeAll { $0.pattern == host.pattern }
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(KM.textSecondary)
                        .iconHelp(L("Remove"))
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Capsule(style: .continuous).fill(KM.subtleFill))
                    .help(host.learnedAt.map { L("Remembered when \(host.pattern) accepted this key on \($0.formatted(date: .abbreviated, time: .omitted))") } ?? host.pattern)
                }
                TextField(hosts.isEmpty ? L("Any host (offered after the matching keys)") : L("Add host"), text: $input)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(minWidth: 160)
                    .onSubmit(add)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(KM.raisedFieldBackground))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(KM.fieldBorder, lineWidth: 0.5))
            Text(L("*.example.com covers a domain, [host]:2222 a port."))
                .font(.system(size: 11))
                .foregroundStyle(KM.textSecondary)
        }
    }

    private func add() {
        let patterns = input.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init).filter { !$0.isEmpty }
        for pattern in patterns where !hosts.contains(where: { $0.pattern.caseInsensitiveCompare(pattern) == .orderedSame }) {
            hosts.append(VaultSSHHost(pattern: pattern))
        }
        input = ""
    }
}

/// Wraps its children onto new lines, for host chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// The SSH agent part of an entry: use it, hosts, confirmation.
struct SSHAgentOptions: View {
    @Binding var isEnabled: Bool
    @Binding var hosts: [VaultSSHHost]
    @Binding var confirmation: VaultSSHConfirmation

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Toggle("", isOn: $isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(KM.success)
                Text(L("Use in SSH agent"))
                    .font(.system(size: 13))
            }
            if isEnabled {
                SSHHostsField(hosts: $hosts)
                HStack(spacing: 10) {
                    Text(L("Confirmation"))
                        .font(.system(size: 12))
                        .foregroundStyle(KM.textSecondary)
                    KMSegmentedControl(
                        options: VaultSSHConfirmation.allCases.map { ($0, $0.title) },
                        selection: $confirmation,
                        fontSize: 12,
                        horizontalPadding: 10
                    )
                    .fixedSize()
                }
                Text(L("Passphrase: this entry’s password."))
                    .font(.system(size: 11))
                    .foregroundStyle(KM.textSecondary)
            }
        }
    }
}

// MARK: - Entries with keys

extension VaultEntry {
    /// The attachment the agent uses as this entry's private key.
    var sshKeyAttachment: VaultAttachment? {
        guard let name = sshAgent?.keyAttachmentName else { return nil }
        return attachments.first { $0.name == name }
    }

    /// The key's public part; the entry's password opens encrypted keys to read the comment too.
    var sshPublicKey: SSHPublicKey? {
        guard let data = sshKeyAttachment?.data else { return nil }
        if let key = try? SSHKeyReader.read(data, passphrase: password) {
            return key.publicKey
        }
        return (try? SSHKeyReader.inspect(data))?.publicKey
    }

    /// "Ed25519 · SHA256:abcd…" for the entry list.
    var sshKeySummary: String? {
        guard let data = sshKeyAttachment?.data, let publicKey = (try? SSHKeyReader.inspect(data))?.publicKey else { return nil }
        return "\(publicKey.algorithm.displayName) · \(publicKey.fingerprint.prefix(15))…"
    }

    /// An attachment that looks like a private key while the agent isn't set up for the entry.
    var suggestedSSHKeyAttachment: VaultAttachment? {
        guard sshAgent == nil else { return nil }
        return attachments.first { SSHKeyReader.looksLikePrivateKey($0.data) }
    }
}

/// The detail of an entry's key: type, fingerprint, status, public key actions, hosts, confirmation and last use.
struct SSHKeyDetailCard: View {
    let entry: VaultEntry
    let defaultConfirmation: VaultSSHConfirmation
    let lastUse: String?

    var body: some View {
        let settings = entry.sshAgent
        let publicKey = entry.sshPublicKey
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "key.horizontal.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(VaultEntryType.sshKey.tileColor))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(publicKey?.algorithm.displayName ?? L("SSH key"))
                            .font(.system(size: 13, weight: .semibold))
                        if let name = settings?.keyAttachmentName {
                            Text(name)
                                .font(.system(size: 11))
                                .foregroundStyle(KM.textSecondary)
                        }
                        statusPill(isOn: settings?.isEnabled == true && publicKey != nil)
                    }
                    if let publicKey {
                        Text(publicKey.fingerprint)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(KM.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    if let comment = publicKey?.comment, !comment.isEmpty {
                        Text(comment)
                            .font(.system(size: 11))
                            .foregroundStyle(KM.textSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)

            if let publicKey {
                HStack(spacing: 8) {
                    Button {
                        SensitiveClipboard.shared.copyPlainText(publicKey.authorizedKeysLine, label: L("Public key"))
                    } label: {
                        Label(L("Copy Public Key"), systemImage: "doc.on.doc")
                    }
                    .buttonStyle(KMButtonStyle(kind: .raised, height: 26, horizontalPadding: 10, fontWeight: .regular, fontSize: 12))
                    Button(L("Save .pub…")) {
                        savePublicKey(publicKey)
                    }
                    .buttonStyle(KMButtonStyle(kind: .raised, height: 26, horizontalPadding: 10, fontWeight: .regular, fontSize: 12))
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }

            row(L("hosts")) {
                if let hosts = settings?.hosts, !hosts.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(hosts, id: \.pattern) { host in
                            HStack(spacing: 4) {
                                Text(host.pattern)
                                    .font(.system(size: 12, design: .monospaced))
                                if host.isLearned {
                                    Text(L("learned"))
                                        .font(.system(size: 10))
                                        .foregroundStyle(KM.accent)
                                }
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(Capsule(style: .continuous).fill(KM.subtleFill))
                            .help(host.learnedAt.map { L("Remembered when \(host.pattern) accepted this key on \($0.formatted(date: .abbreviated, time: .omitted))") } ?? host.pattern)
                        }
                    }
                } else {
                    Text(L("Any host")).font(.system(size: 13))
                }
            }
            row(L("confirmation")) {
                Text((settings?.confirmation ?? defaultConfirmation).title).font(.system(size: 13))
            }
            row(L("last used")) {
                Text(lastUse ?? L("Not used yet"))
                    .font(.system(size: 13))
                    .foregroundStyle(lastUse == nil ? KM.textSecondary : KM.textPrimary)
            }
        }
        .kmCard()
    }

    private func statusPill(isOn: Bool) -> some View {
        Text(isOn ? L("In SSH agent") : L("Not used by the agent"))
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(isOn ? KM.success : KM.textSecondary)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(Capsule(style: .continuous).fill((isOn ? KM.success : KM.textSecondary).opacity(0.12)))
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(KM.textSecondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(alignment: .top) {
            Rectangle().fill(KM.hairline).frame(height: 0.5).padding(.leading, 16)
        }
    }

    private func savePublicKey(_ publicKey: SSHPublicKey) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (entry.sshAgent?.keyAttachmentName ?? "id_ed25519") + ".pub"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? Data((publicKey.authorizedKeysLine + "\n").utf8).write(to: url)
    }
}

/// "This entry has an SSH key · Use in SSH agent" on entries with a key attachment but no agent settings.
struct SSHKeySuggestionBanner: View {
    let attachment: VaultAttachment
    let onUse: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.horizontal.fill")
                .font(.system(size: 12))
                .foregroundStyle(KM.accent)
            Text(L("This entry has an SSH key"))
                .font(.system(size: 12, weight: .medium))
            + Text(" · \(attachment.name)")
                .font(.system(size: 12))
                .foregroundColor(KM.textSecondary)
            Spacer(minLength: 0)
            Button(L("Use in SSH agent"), action: onUse)
                .buttonStyle(KMButtonStyle(kind: .primary, height: 24, horizontalPadding: 10, fontWeight: .semibold, fontSize: 12))
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(KMIconButtonStyle(size: 22, cornerRadius: 5))
            .iconHelp(L("Hide"))
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(KM.accent.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(KM.accent.opacity(0.25), lineWidth: 0.5))
    }
}

/// "SSH agent" in the inline login editor: which attachment is the key, hosts, confirmation.
struct SSHAgentEditorSection: View {
    @Binding var form: VaultEntryForm

    private var isEnabled: Binding<Bool> {
        Binding(
            get: { form.sshAgent?.isEnabled == true },
            set: { isOn in
                if var settings = form.sshAgent {
                    settings.isEnabled = isOn
                    form.sshAgent = settings
                } else if isOn {
                    form.sshAgent = VaultSSHAgentSettings(keyAttachmentName: keyCandidates.first?.name)
                }
            }
        )
    }

    private var keyCandidates: [VaultAttachment] {
        let keys = form.attachments.filter { SSHKeyReader.looksLikePrivateKey($0.data) }
        return keys.isEmpty ? form.attachments : keys
    }

    private func settingsBinding<Value>(_ keyPath: WritableKeyPath<VaultSSHAgentSettings, Value>) -> Binding<Value> {
        Binding(
            get: { (form.sshAgent ?? VaultSSHAgentSettings())[keyPath: keyPath] },
            set: { value in
                var settings = form.sshAgent ?? VaultSSHAgentSettings()
                settings[keyPath: keyPath] = value
                form.sshAgent = settings
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Toggle("", isOn: isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(KM.success)
                Text(L("Use in SSH agent"))
                    .font(.system(size: 13))
            }
            if form.sshAgent?.isEnabled == true {
                HStack(spacing: 8) {
                    Text(L("Key"))
                        .font(.system(size: 12))
                        .foregroundStyle(KM.textSecondary)
                    if keyCandidates.isEmpty {
                        Text(L("No key attachment"))
                            .font(.system(size: 12))
                            .foregroundStyle(KM.textSecondary)
                    } else {
                        Picker("", selection: settingsBinding(\.keyAttachmentName)) {
                            ForEach(keyCandidates, id: \.name) { attachment in
                                Text(keyLabel(attachment)).tag(Optional(attachment.name))
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    Button(action: addKeyFile) {
                        Label(L("Add Key File…"), systemImage: "paperclip")
                    }
                    .buttonStyle(KMButtonStyle(kind: .raised, height: 24, horizontalPadding: 10, fontWeight: .regular, fontSize: 12))
                }
                SSHHostsField(hosts: settingsBinding(\.hosts))
                HStack(spacing: 10) {
                    Text(L("Confirmation"))
                        .font(.system(size: 12))
                        .foregroundStyle(KM.textSecondary)
                    KMSegmentedControl(
                        options: VaultSSHConfirmation.allCases.map { ($0, $0.title) },
                        selection: Binding(
                            get: { form.sshAgent?.confirmation ?? AppSettingsStore.shared.sshDefaultConfirmation },
                            set: { settingsBinding(\.confirmation).wrappedValue = $0 }
                        ),
                        fontSize: 12,
                        horizontalPadding: 10
                    )
                    .fixedSize()
                }
                Text(L("Passphrase: this entry’s password."))
                    .font(.system(size: 11))
                    .foregroundStyle(KM.textSecondary)
            }
        }
    }

    private func keyLabel(_ attachment: VaultAttachment) -> String {
        guard let publicKey = (try? SSHKeyReader.inspect(attachment.data))?.publicKey else { return attachment.name }
        return "\(attachment.name) — \(publicKey.algorithm.displayName)"
    }

    private func addKeyFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.message = L("Choose a private SSH key")
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        form.attachments.removeAll { $0.name == url.lastPathComponent }
        form.attachments.append(VaultAttachment(name: url.lastPathComponent, data: data))
        var settings = form.sshAgent ?? VaultSSHAgentSettings()
        settings.isEnabled = true
        settings.keyAttachmentName = url.lastPathComponent
        form.sshAgent = settings
    }
}
