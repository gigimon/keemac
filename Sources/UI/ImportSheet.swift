import AppKit
import Data
import Domain
import SwiftUI
import UniformTypeIdentifiers

extension VaultImportFormat {
    var title: String {
        switch self {
        case .keePass1: return L("KeePass 1 database (.kdb)")
        case .keePassXML: return L("KeePass XML (KeePass, KeePassXC, MacPass)")
        case .bitwarden: return L("Bitwarden CSV")
        case .onePassword: return L("1Password CSV")
        case .chrome: return L("Chrome / Edge / Brave CSV")
        case .firefox: return L("Firefox CSV")
        case .safari: return L("Safari / Apple Passwords CSV")
        case .lastPass: return L("LastPass CSV")
        case .keePassXC: return L("KeePassXC CSV")
        }
    }

    /// For the default group name: "Imported from Bitwarden · 3 Oct".
    var appName: String {
        switch self {
        case .keePass1: return "KeePass 1"
        case .keePassXML: return "KeePass"
        case .bitwarden: return "Bitwarden"
        case .onePassword: return "1Password"
        case .chrome: return "Chrome"
        case .firefox: return "Firefox"
        case .safari: return "Safari"
        case .lastPass: return "LastPass"
        case .keePassXC: return "KeePassXC"
        }
    }
}

/// Vault → Import…: choose a file (Source), then where and how to add its entries (Review).
struct ImportSheet: View {
    let vault: LoadedVault
    let viewModel: AppViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var isReviewing = false
    @State private var fileURL: URL?
    @State private var fileData: Data?
    @State private var file: VaultImportFile?
    @State private var chosenFormat: VaultImportFormat?
    @State private var error: VaultImportError?
    @State private var isDropTargeted = false
    @State private var destinationPath: String?
    @State private var newGroupName = ""
    @State private var keepsFolders = true
    @State private var skipsDuplicates = true
    @State private var isImporting = false
    @State private var importFailure: String?
    // KeePass 1: the file is read only after its password or key file is given.
    @State private var keePass1Password = ""
    @State private var revealsKeePass1Password = false
    @State private var keePass1KeyFileURL: URL?
    @State private var isUnlockingKeePass1 = false
    @State private var isKeePass1KeyWrong = false
    @FocusState private var isKeePass1PasswordFocused: Bool

    private static let labelWidth: CGFloat = 110
    private static let previewCount = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            stepIndicator
                .frame(maxWidth: .infinity)
                .padding(.top, 16)
                .padding(.bottom, 2)
            if isReviewing, let file {
                review(file)
                    .padding(.top, 18)
            } else {
                source
                    .padding(.top, 18)
            }
            footer
                .padding(.top, 20)
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 18)
        .frame(width: 560)
        .background(KM.sheetBackground)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(KM.accent)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(KM.accent.opacity(0.14)))
            VStack(alignment: .leading, spacing: 1) {
                Text(L("Import"))
                    .font(.system(size: 15, weight: .bold))
                Text(L("Into \(vault.summary.fileName)"))
                    .font(.system(size: 11))
                    .foregroundStyle(KM.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var stepIndicator: some View {
        let current = isReviewing ? 1 : 0
        return HStack(spacing: 10) {
            ForEach(Array([L("merge.step.source", default: "Source"), L("merge.step.review", default: "Review")].enumerated()), id: \.offset) { index, label in
                HStack(spacing: 8) {
                    ZStack {
                        Circle().fill(index <= current ? KM.accent : KM.controlFill)
                        if index < current {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                        } else {
                            Text(String(index + 1))
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(index <= current ? Color.white : KM.textSecondary)
                        }
                    }
                    .frame(width: 22, height: 22)
                    Text(label)
                        .font(.system(size: 12, weight: index == current ? .semibold : .regular))
                        .foregroundStyle(index == current ? KM.textPrimary : KM.textSecondary)
                }
                if index == 0 {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(current > 0 ? KM.accent : KM.separator)
                        .frame(width: 40, height: 2)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Source

    @ViewBuilder
    private var source: some View {
        if fileURL == nil {
            VStack(spacing: 10) {
                VStack(spacing: 10) {
                    Text(L("Drop a file here"))
                        .font(.system(size: 13, weight: .medium))
                    Button(L("Choose…"), action: chooseFile)
                        .buttonStyle(KMButtonStyle(kind: .raised, height: 24, horizontalPadding: 12, fontWeight: .regular, fontSize: 12))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 150)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isDropTargeted ? KM.accent.opacity(0.08) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(isDropTargeted ? KM.accent : KM.fieldBorder, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                )
                .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: drop)
                Text(L("KeePass 1 (.kdb) or KeePass XML from KeePass, KeePassXC or MacPass · CSV from Bitwarden, 1Password, Chrome, Edge, Brave, Firefox, Safari / Apple Passwords, LastPass or KeePassXC"))
                    .font(.system(size: 11))
                    .foregroundStyle(KM.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                // The problem comes first, right under the steps, so it isn't missed below the form.
                if let error, error != .keePass1Locked {
                    errorCard(error)
                }
                fileCard
                if error == .keePass1Locked {
                    keePass1UnlockCard
                }
                if error != .unreadable && error != .unreadableKeePass1 {
                    row(L("Format")) {
                        formatMenu
                    }
                }
                if let file, error == nil {
                    row("") {
                        Text(carriesText(file.format))
                            .font(.system(size: 11))
                            .foregroundStyle(KM.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func carriesText(_ format: VaultImportFormat) -> String {
        switch format {
        case .keePass1:
            return L("Imports groups, attachments and notes. The Backup group is skipped.")
        case .keePassXML:
            return L("Imports groups, history, attachments and custom fields.")
        default:
            return L("Imports title, username, password, URL, notes and TOTP. Folders become groups.")
        }
    }

    /// The locked KeePass 1 file still counts as fine; only a real failure turns the tile red.
    private var hasFileError: Bool {
        error != nil && error != .keePass1Locked
    }

    private var fileSymbol: String {
        if hasFileError {
            return "exclamationmark.triangle.fill"
        }
        if error == .keePass1Locked || file?.format == .keePass1 {
            return "cylinder.split.1x2"
        }
        return file?.format == .keePassXML ? "chevron.left.forwardslash.chevron.right" : "tablecells"
    }

    private var fileCard: some View {
        HStack(spacing: 10) {
            Image(systemName: fileSymbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(hasFileError ? KM.danger : KM.accent)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill((hasFileError ? KM.danger : KM.accent).opacity(0.13)))
            VStack(alignment: .leading, spacing: 1) {
                Text(fileURL?.lastPathComponent ?? "")
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 3) {
                    if error == .keePass1Locked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9))
                    }
                    Text(formatLine)
                        .lineLimit(1)
                }
                .font(.system(size: 11))
                .foregroundStyle(KM.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(L("Choose Another…"), action: chooseFile)
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(KM.accent)
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(KM.raisedFieldBackground))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(KM.softBorder, lineWidth: 0.5))
    }

    private var formatLine: String {
        switch error {
        case .unreadable, .unreadableKeePass1, .wrongKey:
            return L("Can’t be read")
        case .unrecognizedCSV, .formatMismatch:
            return L("CSV · format not recognized")
        case .keePass1Locked:
            return L("KeePass 1 · locked")
        case nil:
            guard let file else {
                return ""
            }
            if file.format == .keePass1 {
                let groups = Set(file.items.flatMap { item in item.folder.indices.map { item.folder[...$0].joined(separator: "/") } }).count
                return "KeePass 1 · \(L("\(file.items.count) entries")) · \(L("\(groups) groups"))"
            }
            return "\(file.format.title) · \(L("\(file.items.count) entries"))"
        }
    }

    /// A locked KeePass 1 file has no `file` yet, but its signature already tells the format.
    private var shownFormat: VaultImportFormat? {
        chosenFormat ?? file?.format ?? (error == .keePass1Locked ? .keePass1 : nil)
    }

    private var formatMenu: some View {
        Menu {
            ForEach(VaultImportFormat.allCases) { format in
                Button(format.title) {
                    chosenFormat = format
                    read()
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(shownFormat?.title ?? L("Choose format…"))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(KM.textSecondary)
            }
            .font(.system(size: 12))
            .padding(.leading, 8)
            .padding(.trailing, 6)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(KM.raisedButtonBackground))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(KM.softBorder, lineWidth: 0.5))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func errorCard(_ error: VaultImportError) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(KM.danger)
            VStack(alignment: .leading, spacing: 2) {
                Text(errorTitle(error))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(KM.danger)
                Text(errorMessage(error))
                    .font(.system(size: 11))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(KM.danger.opacity(0.09)))
    }

    private func errorTitle(_ error: VaultImportError) -> String {
        switch error {
        case .unreadable:
            return L("This file is encrypted or damaged")
        case .unreadableKeePass1, .wrongKey, .keePass1Locked:
            return L("This KeePass 1 file can’t be read")
        case .unrecognizedCSV, .formatMismatch:
            return L("Couldn’t recognize this CSV")
        }
    }

    private func errorMessage(_ error: VaultImportError) -> String {
        switch error {
        case .unreadable:
            return L("Export it again from the other app as an unencrypted CSV or KeePass XML file.")
        case .unreadableKeePass1, .wrongKey, .keePass1Locked:
            return L("It may be damaged or use an unsupported cipher. Open it in KeePass 1 and export KeePass XML instead.")
        case .unrecognizedCSV, .formatMismatch:
            return L("Supported: Bitwarden, 1Password, Chrome, Edge, Brave, Firefox, Safari / Apple Passwords, LastPass and KeePassXC. If it came from one of these, pick it under Format.")
        }
    }

    // MARK: - KeePass 1

    private var keePass1UnlockCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Password for this file"))
                        .font(.system(size: 12))
                        .foregroundStyle(KM.textSecondary)
                    HStack(spacing: 0) {
                        Group {
                            if revealsKeePass1Password {
                                TextField("", text: $keePass1Password)
                            } else {
                                SecureField("", text: $keePass1Password)
                            }
                        }
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($isKeePass1PasswordFocused)
                        .accessibilityLabel(L("Password for this file"))
                        .onChange(of: keePass1Password) {
                            isKeePass1KeyWrong = false
                        }
                        Button {
                            revealsKeePass1Password.toggle()
                        } label: {
                            Image(systemName: revealsKeePass1Password ? "eye.slash" : "eye")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(KMIconButtonStyle(size: 22, cornerRadius: 5))
                        .iconHelp(revealsKeePass1Password ? L("Hide password") : L("Show password"))
                    }
                    .kmField(focused: isKeePass1PasswordFocused, invalid: isKeePass1KeyWrong, height: 28, background: KM.raisedFieldBackground, horizontalPadding: 10)
                    if isKeePass1KeyWrong {
                        Label(L("Wrong password or key file"), systemImage: "exclamationmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(KM.danger)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                Rectangle()
                    .fill(KM.hairline)
                    .frame(height: 0.5)
                    .padding(.horizontal, 14)

                HStack(spacing: 8) {
                    Text(L("Key file"))
                        .font(.system(size: 12))
                        .foregroundStyle(KM.textSecondary)
                    if let keePass1KeyFileURL {
                        HStack(spacing: 4) {
                            Image(systemName: "key.horizontal")
                                .font(.system(size: 11))
                                .foregroundStyle(KM.textSecondary)
                            Text(keePass1KeyFileURL.lastPathComponent)
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button {
                                self.keePass1KeyFileURL = nil
                                isKeePass1KeyWrong = false
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .semibold))
                            }
                            .buttonStyle(KMIconButtonStyle(size: 16, cornerRadius: 8))
                            .iconHelp(L("Remove key file"))
                        }
                    } else {
                        Text(L("None"))
                            .font(.system(size: 12))
                            .foregroundStyle(KM.textTertiary)
                    }
                    Spacer(minLength: 0)
                    Button(L("Choose…"), action: chooseKeePass1KeyFile)
                        .buttonStyle(KMButtonStyle(kind: .raised, height: 22, horizontalPadding: 10, fontWeight: .regular, fontSize: 12))
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(KM.insetFill))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(light: .black(0.06), dark: .white(0.06)), lineWidth: 0.5))
            .disabled(isUnlockingKeePass1)
            .opacity(isUnlockingKeePass1 ? 0.55 : 1)

            Text(L("The file is only read. Nothing is saved to it."))
                .font(.system(size: 11))
                .foregroundStyle(KM.textTertiary)
                .padding(.leading, 4)
        }
        .onAppear {
            isKeePass1PasswordFocused = true
        }
    }

    private var canUnlockKeePass1: Bool {
        (!keePass1Password.isEmpty || keePass1KeyFileURL != nil) && !isUnlockingKeePass1
    }

    private func chooseKeePass1KeyFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = L("Choose the key file for this KeePass 1 database")
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        keePass1KeyFileURL = url
        isKeePass1KeyWrong = false
    }

    private func unlockKeePass1() {
        guard canUnlockKeePass1, let fileData else {
            return
        }
        var keyFileData: Data?
        if let keePass1KeyFileURL {
            let accessed = keePass1KeyFileURL.startAccessingSecurityScopedResource()
            keyFileData = try? Data(contentsOf: keePass1KeyFileURL)
            if accessed {
                keePass1KeyFileURL.stopAccessingSecurityScopedResource()
            }
            guard keyFileData != nil else {
                isKeePass1KeyWrong = true
                return
            }
        }
        let password = keePass1Password
        isUnlockingKeePass1 = true
        isKeePass1KeyWrong = false
        Task {
            // Key derivation in KeePass 1 can take a moment; keep the sheet responsive.
            let result = await Task.detached {
                Result { try VaultImporter.readKeePass1(fileData, password: password, keyFileData: keyFileData) }
            }.value
            isUnlockingKeePass1 = false
            switch result {
            case .success(let read):
                accept(read)
                keePass1Password = ""
            case .failure(VaultImportError.wrongKey):
                isKeePass1KeyWrong = true
                isKeePass1PasswordFocused = true
                // Select the rejected password so typing replaces it.
                DispatchQueue.main.async {
                    NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                }
            case .failure:
                file = nil
                error = .unreadableKeePass1
            }
        }
    }

    // MARK: - Review

    private func review(_ file: VaultImportFile) -> some View {
        let plan = ImportPlan(file: file, existing: vault.entries, skipsDuplicates: skipsDuplicates)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                row(L("Import into")) {
                    HStack(spacing: 8) {
                        destinationMenu
                        if destinationPath == nil {
                            TextField("", text: $newGroupName)
                                .textFieldStyle(.plain)
                                .kmField(height: 28, background: KM.raisedFieldBackground)
                        }
                    }
                }
                row(L("Folders")) {
                    HStack(spacing: 8) {
                        Toggle("", isOn: $keepsFolders)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .tint(KM.success)
                        Text(L("Keep folders as subgroups"))
                            .font(.system(size: 13))
                    }
                }
                row(L("Duplicates")) {
                    KMSegmentedControl(
                        options: [(true, L("Skip duplicates (\(plan.duplicates))")), (false, L("Import anyway"))],
                        selection: $skipsDuplicates,
                        fontSize: 12,
                        horizontalPadding: 12
                    )
                    .fixedSize()
                }
            }

            chips(plan)
                .padding(.top, 16)

            if !file.skippedLines.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                    Text(skippedText(file.skippedLines))
                }
                .font(.system(size: 12))
                .foregroundStyle(KM.warning)
                .padding(.top, 10)
            }

            previewList(plan)
                .padding(.top, 12)

            if let importFailure {
                Text(importFailure)
                    .font(.system(size: 11))
                    .foregroundStyle(KM.danger)
                    .padding(.top, 8)
            }
        }
    }

    private var destinationMenu: some View {
        let groups = vault.groups.filter { !$0.isTrash && $0.path.contains(".") }
        let rootDepth = (vault.groups.first { !$0.path.contains(".") }?.path.split(separator: ".").count ?? 1)
        return Menu {
            Button(L("New group")) {
                destinationPath = nil
            }
            Divider()
            ForEach(groups, id: \.path) { group in
                let depth = group.path.split(separator: ".").count - rootDepth - 1
                Button(String(repeating: "    ", count: max(0, depth)) + group.title) {
                    destinationPath = group.path
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(destinationPath.map { GroupPathFormatter.title(of: $0) } ?? L("New group"))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(KM.textSecondary)
            }
            .font(.system(size: 12))
            .padding(.leading, 8)
            .padding(.trailing, 6)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(KM.raisedButtonBackground))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(KM.softBorder, lineWidth: 0.5))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func chips(_ plan: ImportPlan) -> some View {
        let all: [(String, Color, Int)] = [
            (L("\(plan.newCount) new"), KM.success, plan.newCount),
            (L("\(plan.duplicates) duplicates"), KM.warning, plan.duplicates),
            (L("\(plan.withoutPassword) without password"), KM.textTertiary, plan.withoutPassword),
            (L("\(plan.withTOTP) with TOTP"), KM.accent, plan.withTOTP)
        ]
        return HStack(spacing: 6) {
            ForEach(Array(all.filter { $0.2 > 0 || $0.1 == KM.success }.enumerated()), id: \.offset) { _, chip in
                HStack(spacing: 6) {
                    Circle().fill(chip.1).frame(width: 7, height: 7)
                    Text(chip.0)
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Capsule(style: .continuous).fill(KM.subtleFill))
            }
        }
    }

    private func previewList(_ plan: ImportPlan) -> some View {
        let shown = Array(plan.items.prefix(Self.previewCount))
        let groupName = destinationPath.map { GroupPathFormatter.title(of: $0) } ?? (newGroupName.isEmpty ? L("Imported") : newGroupName)
        return VStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.offset) { index, item in
                HStack(spacing: 10) {
                    LetterTile(title: item.title, size: 26, cornerRadius: 7, fontSize: 12)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title)
                            .font(.system(size: 13))
                            .lineLimit(1)
                        Text([item.username, Self.domain(of: item.url)].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: 11))
                            .foregroundStyle(KM.textSecondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // The group name gives way first, so the folder stays readable.
                    HStack(spacing: 0) {
                        Text(groupName)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if keepsFolders, !item.folder.isEmpty {
                            Text(" › " + item.folder.joined(separator: " › "))
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(KM.textSecondary)
                    .frame(maxWidth: 200, alignment: .trailing)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .overlay(alignment: .top) {
                    if index > 0 {
                        Rectangle().fill(KM.hairline).frame(height: 0.5)
                    }
                }
            }
            if plan.items.count > Self.previewCount {
                Text(L("and \(plan.items.count - Self.previewCount) more"))
                    .font(.system(size: 12))
                    .foregroundStyle(KM.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 48)
                    .padding(.vertical, 8)
                    .overlay(alignment: .top) {
                        Rectangle().fill(KM.hairline).frame(height: 0.5)
                    }
            } else if plan.items.isEmpty {
                Text(L("Nothing new to import."))
                    .font(.system(size: 12))
                    .foregroundStyle(KM.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(KM.insetFill))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(KM.hairline, lineWidth: 0.5))
    }

    private func skippedText(_ lines: [Int]) -> String {
        let shown = lines.prefix(5).map(String.init).joined(separator: ", ")
        let list = lines.count > 5 ? shown + ", …" : shown
        return L("\(lines.count) rows skipped") + ": " + (lines.count == 1 ? L("line \(list)") : L("lines \(list)"))
    }

    // MARK: - Footer

    private var footer: some View {
        let plan = file.map { ImportPlan(file: $0, existing: vault.entries, skipsDuplicates: skipsDuplicates) }
        let canContinue = file != nil && error == nil
        let isLocked = error == .keePass1Locked
        return HStack(spacing: 8) {
            Spacer(minLength: 0)
            Button(isReviewing ? L("Back") : L("Cancel")) {
                if isReviewing {
                    isReviewing = false
                } else {
                    dismiss()
                }
            }
            .buttonStyle(KMButtonStyle(kind: .secondary, height: 30))
            .keyboardShortcut(.cancelAction)
            .disabled(isImporting)
            Button {
                if isReviewing {
                    performImport()
                } else if isLocked {
                    unlockKeePass1()
                } else if canContinue {
                    isReviewing = true
                }
            } label: {
                HStack(spacing: 6) {
                    if isUnlockingKeePass1 {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(.white)
                    }
                    Text(primaryTitle(plan: plan, isLocked: isLocked))
                }
            }
            .buttonStyle(KMButtonStyle(kind: .primary, height: 30, horizontalPadding: 18, fontWeight: .semibold))
            .keyboardShortcut(.defaultAction)
            .disabled(isReviewing ? (plan?.newCount ?? 0) == 0 || isImporting : (isLocked ? !canUnlockKeePass1 : !canContinue))
        }
    }

    private func primaryTitle(plan: ImportPlan?, isLocked: Bool) -> String {
        if isReviewing {
            return L("Import \(plan?.newCount ?? 0) Entries")
        }
        if isLocked {
            return isUnlockingKeePass1 ? L("Unlocking…") : L("Unlock")
        }
        return L("Continue")
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(KM.textSecondary)
                .frame(width: Self.labelWidth, alignment: .trailing)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Actions

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .xml, .plainText, .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = L("Choose a KeePass 1, CSV or KeePass XML file to import")
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        open(url)
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else {
            return false
        }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else {
                return
            }
            Task { @MainActor in
                open(url)
            }
        }
        return true
    }

    private func open(_ url: URL) {
        fileURL = url
        chosenFormat = nil
        destinationPath = nil
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
        fileData = try? Data(contentsOf: url)
        read()
    }

    private func read() {
        keePass1Password = ""
        revealsKeePass1Password = false
        keePass1KeyFileURL = nil
        isKeePass1KeyWrong = false
        guard let fileData else {
            file = nil
            error = .unreadable
            return
        }
        do {
            accept(try VaultImporter.read(fileData, format: chosenFormat))
        } catch let importError as VaultImportError {
            file = nil
            error = importError
        } catch {
            file = nil
            self.error = .unreadable
        }
    }

    private func accept(_ read: VaultImportFile) {
        file = read
        error = nil
        newGroupName = L("Imported from \(read.format.appName)") + " · " + Date().formatted(.dateTime.day().month(.abbreviated))
    }

    private func performImport() {
        guard let file else {
            return
        }
        isImporting = true
        importFailure = nil
        let options = VaultImportOptions(
            destination: destinationPath.map { .group(path: $0) } ?? .newGroup(title: newGroupName),
            keepsFolders: keepsFolders,
            skipsDuplicates: skipsDuplicates
        )
        Task {
            do {
                try await viewModel.importEntries(file, options: options)
                dismiss()
            } catch {
                importFailure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            isImporting = false
        }
    }

    private static func domain(of url: String) -> String {
        guard let host = URLComponents(string: url.contains("://") ? url : "https://" + url)?.host else {
            return ""
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// What an import would add, counted the way the loader imports (duplicates also within the file).
struct ImportPlan {
    let items: [VaultImportItem]
    let duplicates: Int
    let withoutPassword: Int
    let withTOTP: Int

    var newCount: Int { items.count }

    init(file: VaultImportFile, existing: [VaultEntry], skipsDuplicates: Bool) {
        var seen = Set(existing.filter { !$0.isTrashed }.map {
            VaultImportItem.duplicateKey(title: $0.title, username: $0.username ?? "", url: $0.url?.absoluteString ?? "")
        })
        var kept: [VaultImportItem] = []
        var duplicates = 0
        for item in file.items {
            let key = item.duplicateKey
            if seen.contains(key) {
                duplicates += 1
                if skipsDuplicates {
                    continue
                }
            }
            seen.insert(key)
            kept.append(item)
        }
        items = kept
        self.duplicates = duplicates
        withoutPassword = kept.filter { $0.password.isEmpty && !$0.isSecureNote }.count
        withTOTP = kept.filter { !$0.otp.isEmpty }.count
    }
}
