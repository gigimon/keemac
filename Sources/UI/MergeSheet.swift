import AppKit
import Data
import Domain
import SwiftUI

/// Preview and confirmation for merging another version of the database:
/// the file changed on disk (Ask mode), conflicting copies, or any database picked by the user.
struct MergeSheet: View {
    private enum Phase: Equatable {
        case source
        case loading
        case review(VaultMergeSummary)
        case merging(VaultMergeSummary)
        /// The other version couldn't be read; only Cancel is left.
        case unavailable
    }

    let request: AppViewModel.MergeSheetRequest
    let vault: LoadedVault
    let databaseURL: URL?
    let viewModel: AppViewModel

    @State private var phase: Phase
    @State private var sourceURL: URL?
    @State private var password = ""
    @State private var revealPassword = false
    @State private var keyFileURL: URL?
    @State private var errorMessage: String?
    /// The chosen database is being decrypted; the form stays in place so focus survives a wrong key.
    @State private var isOpeningSource = false
    @FocusState private var isPasswordFocused: Bool

    init(request: AppViewModel.MergeSheetRequest, vault: LoadedVault, databaseURL: URL?, viewModel: AppViewModel) {
        self.request = request
        self.vault = vault
        self.databaseURL = databaseURL
        self.viewModel = viewModel
        _phase = State(initialValue: request.kind == .database ? .source : .loading)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if isWizard {
                stepIndicator
                    .frame(maxWidth: .infinity)
                    .padding(.top, 16)
                    .padding(.bottom, 2)
            }

            switch phase {
            case .source:
                sourceForm
                    .padding(.top, 18)
            case .loading:
                loadingView
            case .unavailable:
                unavailableView
            case .review(let summary), .merging(let summary):
                preview(summary)
            }

            footer
                .padding(.top, 20)
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 18)
        .frame(width: 560)
        .background(KM.sheetBackground)
        .task {
            await loadInitialPreview()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: isWizard ? "arrow.triangle.merge" : "arrow.triangle.2.circlepath.icloud")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(KM.accent)
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(KM.accent.opacity(0.14))
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(KM.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var isWizard: Bool {
        request.kind == .database
    }

    private var isReviewing: Bool {
        switch phase {
        case .review, .merging:
            return true
        case .source, .loading, .unavailable:
            return false
        }
    }

    private var title: String {
        switch request.kind {
        case .diskChanges:
            return L("Changes from \(vault.summary.fileName)")
        case .database:
            if phase == .source || sourceURL == nil {
                return L("Merge Database")
            }
            return L("Changes from \(sourceURL?.lastPathComponent ?? "")")
        case .conflictCopies(let copies):
            if copies.count == 1, let copy = copies.first {
                return L("Changes from \(copy.fileURL.lastPathComponent)")
            }
            return L("Changes from \(copies.count) conflicting copies")
        }
    }

    private var subtitle: String {
        switch request.kind {
        case .diskChanges:
            return L("Modified on disk \(RelativeDateFormatter.modified(modificationDate(of: databaseURL)))")
        case .database:
            if phase == .source || sourceURL == nil {
                return L("Choose a database to merge into \(vault.summary.fileName)")
            }
            return L("Modified \(Self.dateTimeText(modificationDate(of: sourceURL)))")
        case .conflictCopies(let copies):
            var providers: [String] = []
            for copy in copies where !providers.contains(copy.provider.rawValue) {
                providers.append(copy.provider.rawValue)
            }
            let latest = copies.compactMap(\.modifiedAt).max()
            return "\(Self.joined(providers)) · \(Self.dateTimeText(latest))"
        }
    }

    // MARK: - Wizard

    private var stepIndicator: some View {
        let current = phase == .source ? 0 : 1
        return HStack(spacing: 10) {
            ForEach(Array([L("merge.step.source", default: "Source"), L("merge.step.review", default: "Review")].enumerated()), id: \.offset) { index, label in
                HStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(index <= current ? KM.accent : KM.controlFill)
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
    }

    private var sourceForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            formRow(L("Database")) {
                HStack(spacing: 10) {
                    Image(systemName: "cylinder.split.1x2")
                        .font(.system(size: 16))
                        .foregroundStyle(KM.accent)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(sourceURL?.lastPathComponent ?? L("No database selected"))
                            .font(.system(size: 13))
                            .foregroundStyle(sourceURL == nil ? KM.textSecondary : KM.textPrimary)
                        if let sourceURL {
                            Text(UnlockView.displayDirectory(of: sourceURL))
                                .font(.system(size: 11))
                                .foregroundStyle(KM.textSecondary)
                        }
                    }
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button(L("Choose…"), action: chooseSource)
                        .buttonStyle(KMButtonStyle(kind: .raised, height: 24, horizontalPadding: 10, fontWeight: .regular, fontSize: 12))
                }
                .padding(.leading, 10)
                .padding(.trailing, 8)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(KM.raisedFieldBackground))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(KM.softBorder, lineWidth: 0.5))
            }

            formRow(L("Password")) {
                HStack(spacing: 0) {
                    Group {
                        if revealPassword {
                            TextField(L("Master password of that database"), text: $password)
                        } else {
                            SecureField(L("Master password of that database"), text: $password)
                        }
                    }
                    .textFieldStyle(.plain)
                    .focused($isPasswordFocused)
                    .onSubmit(advance)
                    Button {
                        revealPassword.toggle()
                    } label: {
                        Image(systemName: revealPassword ? "eye.slash" : "eye")
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(KM.textSecondary)
                    .iconHelp(revealPassword ? L("Hide Password") : L("Show Password"))
                }
                .kmField(focused: isPasswordFocused, background: KM.raisedFieldBackground)
            }

            formRow(L("Key file")) {
                if let keyFileURL {
                    HStack(spacing: 8) {
                        Image(systemName: "key.horizontal")
                            .font(.system(size: 13))
                            .foregroundStyle(KM.accent)
                        Text(keyFileURL.lastPathComponent)
                            .font(.system(size: 13))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            self.keyFileURL = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(KMIconButtonStyle(size: 24, cornerRadius: 6))
                        .iconHelp(L("Remove Key File"))
                    }
                    .padding(.leading, 10)
                    .padding(.trailing, 4)
                    .frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(KM.insetFill))
                } else {
                    Button(action: chooseKeyFile) {
                        HStack(spacing: 8) {
                            Image(systemName: "paperclip")
                                .font(.system(size: 13))
                            Text(L("No key file (optional)"))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(L("Choose…"))
                                .fontWeight(.medium)
                                .foregroundStyle(KM.accent)
                        }
                        .font(.system(size: 13))
                        .foregroundStyle(KM.textSecondary)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .contentShape(Rectangle())
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(KM.fieldBorder, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func formRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(KM.textSecondary)
                .frame(width: 90, alignment: .trailing)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Preview

    private var loadingView: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(L("Reading changes…"))
                .font(.system(size: 12))
                .foregroundStyle(KM.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    private var unavailableView: some View {
        VStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24))
                .foregroundStyle(KM.warning)
            Text(L("Couldn’t read the other version"))
                .font(.system(size: 13, weight: .semibold))
            Text(unavailableHint)
                .font(.system(size: 11))
                .foregroundStyle(KM.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    private var unavailableHint: String {
        if case .conflictCopies = request.kind {
            return L("A copy may use a different master key. Open it with Vault → Merge Database… instead.")
        }
        return L("The file may still be syncing. Try again in a moment.")
    }

    @ViewBuilder
    private func preview(_ summary: VaultMergeSummary) -> some View {
        if summary.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 26))
                    .foregroundStyle(KM.success)
                Text(L("No new changes"))
                    .font(.system(size: 13, weight: .semibold))
                Text(L("\(vault.summary.fileName) already has everything from this version."))
                    .font(.system(size: 11))
                    .foregroundStyle(KM.textSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 6) {
                    ForEach(VaultMergeChange.Kind.allCases, id: \.self) { style in
                        let count = summary.count(of: style)
                        if count > 0 {
                            HStack(spacing: 6) {
                                Circle().fill(style.color).frame(width: 7, height: 7)
                                Text(style.countLabel(count))
                            }
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 10)
                            .frame(height: 24)
                            .background(Capsule(style: .continuous).fill(KM.subtleFill))
                        }
                    }
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(VaultMergeChange.Kind.allCases, id: \.self) { style in
                            let changes = summary.changes.filter { $0.kind == style }
                            if !changes.isEmpty {
                                changeGroup(style.title, changes: changes)
                            }
                        }
                    }
                }
                .frame(maxHeight: 330)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 16)
        }
    }

    private func changeGroup(_ title: String, changes: [VaultMergeChange]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .padding(.leading, 4)
            VStack(spacing: 0) {
                ForEach(Array(changes.enumerated()), id: \.element.id) { index, change in
                    changeRow(change)
                        .overlay(alignment: .top) {
                            if index > 0 {
                                Rectangle().fill(KM.hairline).frame(height: 0.5)
                            }
                        }
                }
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(KM.insetFill))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color(light: .black(0.06), dark: .white(0.06)), lineWidth: 0.5)
            )
        }
    }

    private func changeRow(_ change: VaultMergeChange) -> some View {
        let entry = vault.entries.first { $0.id == change.entryID }
        return HStack(spacing: 10) {
            LetterTile(
                title: change.title,
                size: 26,
                cornerRadius: 7,
                fontSize: 12,
                colorHex: entry?.backgroundColorHex,
                iconPNGData: entry?.iconPNGData,
                iconID: entry?.iconID
            )
            VStack(alignment: .leading, spacing: 0) {
                Text(change.title.isEmpty ? L("Untitled") : change.title)
                    .font(.system(size: 13))
                Text(detail(for: change))
                    .font(.system(size: 11))
                    .foregroundStyle(KM.textSecondary)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            if change.isConflict {
                Text(L("conflict"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(lightHex: 0xC75F00, darkHex: 0xFF9F0A))
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background(Capsule(style: .continuous).fill(KM.warning.opacity(0.14)))
                    .help(L("Both versions were edited. The older one is kept in the entry’s history."))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func detail(for change: VaultMergeChange) -> String {
        let rootPath = vault.groups.first(where: { !$0.path.contains(".") })?.path ?? ""
        let group = GroupPathFormatter.display(change.groupPath, rootPath: rootPath)
        switch change.kind {
        case .added, .deleted:
            return group
        case .updated:
            guard !change.changedFields.isEmpty else {
                return L("Your version is kept, the other one goes to history")
            }
            let fields = change.changedFields.map(Self.fieldTitle).joined(separator: ", ")
            return fields.prefix(1).uppercased() + fields.dropFirst()
        case .moved:
            let from = change.previousGroupPath.map { GroupPathFormatter.display($0, rootPath: rootPath) } ?? "?"
            return "\(from) → \(group)"
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if let errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 13))
                    Text(errorMessage)
                        .lineLimit(2)
                }
                .font(.system(size: 12))
                .foregroundStyle(KM.danger)
            }
            Spacer(minLength: 0)
            if isOpeningSource {
                ProgressView()
                    .controlSize(.small)
            }
            Button(isWizard && isReviewing ? L("Back") : L("Cancel"), action: cancel)
                .buttonStyle(KMButtonStyle(kind: .secondary, height: 30, fontWeight: .regular))
                .keyboardShortcut(.cancelAction)
                .disabled(isMerging)
            Button(primaryTitle, action: advance)
                .buttonStyle(KMButtonStyle(kind: .primary, height: 30, horizontalPadding: 18, fontWeight: .semibold))
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdvance)
        }
    }

    private var isMerging: Bool {
        if case .merging = phase {
            return true
        }
        return false
    }

    private var primaryTitle: String {
        switch phase {
        case .source:
            return L("Continue")
        case .loading, .review, .merging, .unavailable:
            return isWizard ? L("Merge Into \(vault.summary.fileName)") : L("Merge")
        }
    }

    private var canAdvance: Bool {
        switch phase {
        case .source:
            return !isOpeningSource && sourceURL != nil && (!password.isEmpty || keyFileURL != nil)
        case .review:
            return true
        case .loading, .merging, .unavailable:
            return false
        }
    }

    // MARK: - Actions

    private func loadInitialPreview() async {
        switch request.kind {
        case .database:
            isPasswordFocused = true
        case .diskChanges:
            do {
                phase = .review(try await viewModel.previewDiskChanges())
            } catch {
                fail(error, fallback: .unavailable)
            }
        case .conflictCopies(let copies):
            do {
                phase = .review(try await viewModel.prepareMerge(from: copies.map { VaultMergeSource(fileURL: $0.fileURL) }))
            } catch {
                fail(error, fallback: .unavailable)
            }
        }
    }

    private func advance() {
        guard canAdvance else {
            return
        }
        errorMessage = nil
        switch phase {
        case .source:
            guard let sourceURL else {
                return
            }
            if sourceURL.standardizedFileURL == databaseURL?.standardizedFileURL {
                errorMessage = L("This database is already open.")
                return
            }
            let source = VaultMergeSource(fileURL: sourceURL, masterPassword: password, keyFileURL: keyFileURL)
            isOpeningSource = true
            Task {
                do {
                    let summary = try await viewModel.prepareMerge(from: [source])
                    isOpeningSource = false
                    phase = .review(summary)
                } catch {
                    isOpeningSource = false
                    errorMessage = L("Couldn’t open this database with the given key.")
                    password = ""
                    isPasswordFocused = true
                }
            }
        case .review(let summary):
            phase = .merging(summary)
            Task {
                do {
                    if request.kind == .diskChanges {
                        await viewModel.mergeDiskChanges()
                        viewModel.dismissMergeSheet()
                    } else {
                        try await viewModel.commitPreparedMerge(sourceName: sourceName)
                    }
                } catch {
                    fail(error, fallback: .review(summary))
                }
            }
        case .loading, .merging, .unavailable:
            return
        }
    }

    private func cancel() {
        if isWizard, isReviewing {
            errorMessage = nil
            phase = .source
            return
        }
        viewModel.dismissMergeSheet()
    }

    private var sourceName: String {
        switch request.kind {
        case .diskChanges:
            return vault.summary.fileName
        case .database:
            return sourceURL?.lastPathComponent ?? L("database")
        case .conflictCopies(let copies):
            return copies.count == 1 ? copies[0].fileURL.lastPathComponent : L("\(copies.count) conflicting copies")
        }
    }

    private func fail(_ error: Error, fallback: Phase) {
        phase = fallback
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func chooseSource() {
        guard let url = VaultFilePicker.chooseVault(prompt: L("Choose")) else {
            return
        }
        sourceURL = url
        errorMessage = nil
        isPasswordFocused = true
    }

    private func chooseKeyFile() {
        if let url = VaultFilePicker.chooseKeyFile() {
            keyFileURL = url
        }
    }

    private func modificationDate(of url: URL?) -> Date? {
        guard let url else {
            return nil
        }
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private static func dateTimeText(_ date: Date?) -> String {
        guard let date else {
            return L("unknown date")
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private static func joined(_ items: [String]) -> String {
        ListFormatter.localizedString(byJoining: items)
    }

    /// Field names from `VaultMergeDiff.changedFields`, for the "Updated" rows.
    private static func fieldTitle(_ field: String) -> String {
        switch field {
        case "title": return L("title")
        case "username": return L("username")
        case "password": return L("password")
        case "website": return L("website")
        case "notes": return L("notes")
        case "tags": return L("tags")
        case "one-time password": return L("one-time password")
        case "attachments": return L("attachments")
        case "custom fields": return L("custom fields")
        case "expiry": return L("expiry")
        default: return field
        }
    }
}

private extension VaultMergeChange.Kind {
    var title: String {
        switch self {
        case .added: return L("Added")
        case .updated: return L("Updated")
        case .deleted: return L("Deleted")
        case .moved: return L("Moved")
        }
    }

    func countLabel(_ count: Int) -> String {
        switch self {
        case .added: return L("\(count) added")
        case .updated: return L("\(count) updated")
        case .deleted: return L("\(count) deleted")
        case .moved: return L("\(count) moved")
        }
    }

    var color: Color {
        switch self {
        case .added: return KM.success
        case .updated: return KM.accent
        case .deleted: return KM.destructive
        case .moved: return Color(lightHex: 0xAF52DE, darkHex: 0xBF5AF2)
        }
    }
}
