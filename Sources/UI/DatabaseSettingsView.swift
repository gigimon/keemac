import AppKit
import Data
import Domain
import SwiftUI

/// A group offered as the entry templates group.
public struct TemplateGroupOption: Identifiable, Sendable {
    public let path: String
    public let title: String
    public let depth: Int
    public let entryCount: Int

    public var id: String { path }

    public init(path: String, title: String, depth: Int, entryCount: Int) {
        self.path = path
        self.title = title
        self.depth = depth
        self.entryCount = entryCount
    }
}

/// Settings stored in the open database: one scrolling sheet of cards, each saved on its own.
public struct DatabaseSettingsView: View {
    @Bindable var viewModel: AppViewModel
    /// Groups for the templates picker; nil hides it (KDBX 3.1 has no entry types).
    let templateGroups: [TemplateGroupOption]?

    @Environment(\.dismiss) private var dismiss

    private enum Busy: Equatable {
        case general
        case encryption
        case recycleBin
        case history
        case icons
    }

    /// What was last read from or saved to the database.
    @State private var saved: VaultDatabaseSettings?
    @State private var draft = VaultDatabaseSettings()
    @State private var status: VaultMaintenanceStatus?
    @State private var binEnabled = true
    /// "" keeps the current bin group, `newBinGroupTag` asks for a new one, anything else is a group path.
    @State private var binGroup = ""
    @State private var history = VaultHistoryLimits()
    @State private var busy: Busy?
    @State private var unlockSeconds: Double?
    @State private var loadError: String?
    @State private var errorMessage: String?
    @State private var toast: String?
    @State private var confirmRequest: ConfirmRequest?
    @State private var estimateTask: Task<Void, Never>?
    @State private var showsChangeMasterKey = false

    private static let newBinGroupTag = "\u{1}new"

    public init(viewModel: AppViewModel, templateGroups: [TemplateGroupOption]? = nil) {
        self.viewModel = viewModel
        self.templateGroups = templateGroups
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(KM.hairline).frame(height: 0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let loadError {
                        Label(loadError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(KM.danger)
                    } else if saved == nil || status == nil {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        generalCard
                        entryTypesCard
                        encryptionCard
                        recycleBinCard
                        historyCard
                        masterKeyCard
                        maintenanceCard
                        additionalDatabasesCard
                    }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(KM.danger)
                            .accessibilityIdentifier("dbSettings.error")
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
            Rectangle().fill(KM.hairline).frame(height: 0.5)
            HStack {
                Spacer()
                Button(L("Close")) {
                    dismiss()
                }
                .buttonStyle(KMButtonStyle(kind: .secondary, height: 30, horizontalPadding: 18))
                .keyboardShortcut(.cancelAction)
                .disabled(busy != nil)
                .accessibilityIdentifier("dbSettings.close")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 620, height: 700)
        .background(KM.sheetBackground)
        .overlay(alignment: .bottom) {
            if let toast {
                Label(toast, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(KM.toastText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(KM.toastBackground))
                    .padding(.bottom, 64)
                    .transition(.opacity)
                    .accessibilityIdentifier("dbSettings.toast")
            }
        }
        .task {
            await reload()
        }
        .onChange(of: encryptionKey) {
            scheduleUnlockEstimate()
        }
        .overlay {
            if let confirmRequest {
                ConfirmDialog(request: confirmRequest) {
                    self.confirmRequest = nil
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: confirmRequest?.id)
        .sheet(isPresented: $showsChangeMasterKey) {
            ChangeMasterKeySheet(viewModel: viewModel, hasPassword: status?.hasPassword ?? true, hardwareKey: status?.hardwareKey) { generatedFile in
                showToast(generatedFile.map { L("Master key changed · \($0) created") } ?? L("Master key changed"))
                Task { await reloadStatus() }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "cylinder.split.1x2")
                .font(.system(size: 18))
                .foregroundStyle(KM.accent)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(KM.accent.opacity(0.14)))
            VStack(alignment: .leading, spacing: 1) {
                Text(L("Database Settings"))
                    .font(.system(size: 15, weight: .bold))
                Text(viewModel.selectedVaultURL?.lastPathComponent ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(KM.textSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    // MARK: General

    private var generalCard: some View {
        card(L("General")) {
            row(L("Name"), isFirst: true) {
                TextField(L("Database name"), text: $draft.name)
                    .textFieldStyle(.plain)
                    .kmField(height: 26)
                    .frame(width: 300)
                    .accessibilityIdentifier("dbSettings.name")
            }
            row(L("Description")) {
                TextField(L("Optional description"), text: $draft.details, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...3)
                    .kmField(height: nil)
                    .frame(width: 300)
            }
            row(L("Location")) {
                Text(locationText)
                    .font(.system(size: 12))
                    .foregroundStyle(KM.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            footer {
                saveButton(L("Save General"), busy: .general, enabled: generalDirty) {
                    var settings = saved ?? draft
                    settings.name = draft.name
                    settings.details = draft.details
                    try await viewModel.updateDatabaseSettings(settings)
                    saved = settings
                    showToast(L("Saved."))
                }
                .accessibilityIdentifier("dbSettings.saveGeneral")
            }
        }
    }

    private var generalDirty: Bool {
        guard let saved else { return false }
        return saved.name != draft.name || saved.details != draft.details
    }

    private var locationText: String {
        guard let path = viewModel.selectedVaultURL?.deletingLastPathComponent().path else {
            return ""
        }
        return (path as NSString).abbreviatingWithTildeInPath
    }

    // MARK: Entry types

    @ViewBuilder
    private var entryTypesCard: some View {
        if let templateGroups {
            card(L("Entry Types")) {
                row(L("Templates group"), subtitle: templatesSubtitle(templateGroups), isFirst: true) {
                    Picker("", selection: Binding(
                        get: { saved?.templatesGroupPath ?? "" },
                        set: { path in
                            Task {
                                await perform(nil) {
                                    var settings = saved ?? draft
                                    settings.templatesGroupPath = path.isEmpty ? nil : path
                                    try await viewModel.updateDatabaseSettings(settings)
                                    saved = settings
                                    draft.templatesGroupPath = settings.templatesGroupPath
                                }
                            }
                        }
                    )) {
                        Text(L("None")).tag("")
                        ForEach(templateGroups) { group in
                            Text(String(repeating: "    ", count: group.depth) + group.title).tag(group.path)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(busy != nil)
                }
            }
        }
    }

    private func templatesSubtitle(_ groups: [TemplateGroupOption]) -> String {
        guard let path = saved?.templatesGroupPath, let group = groups.first(where: { $0.path == path }) else {
            return L("New Entry offers only the built-in types.")
        }
        let count = group.entryCount
        return L("Entries in \(group.title) appear as types in New Entry: \(count).")
    }

    // MARK: Encryption

    private var encryptionCard: some View {
        card(L("Encryption")) {
            row(L("Cipher"), isFirst: true) {
                KMSegmentedControl(
                    options: VaultCipher.allCases.map { ($0, $0.displayName) },
                    selection: $draft.cipher,
                    identifierPrefix: "dbSettings.cipher"
                )
            }
            row(L("Key derivation"), subtitle: draft.kdf.isArgon
                ? L("Memory-hard. Resists GPU and ASIC cracking.")
                : L("Legacy. Use for KeePass 2.34 and older.")) {
                KMSegmentedControl(
                    options: [VaultKDFAlgorithm.argon2id, .argon2d, .aes].map { ($0, $0.displayName) },
                    selection: $draft.kdf,
                    identifierPrefix: "dbSettings.kdf"
                )
            }
            if draft.kdf.isArgon {
                row(L("Memory")) {
                    presetMenu(
                        value: draft.argonMemoryMiB,
                        presets: [16, 32, 64, 128, 256, 512, 1024],
                        label: { L("\(Int($0)) MB") },
                        select: { draft.argonMemoryMiB = $0 }
                    )
                }
                row(L("Iterations")) {
                    presetMenu(
                        value: draft.argonIterations,
                        presets: [2, 5, 10, 20, 50],
                        label: { L("\(Int($0)) iterations") },
                        select: { draft.argonIterations = $0 }
                    )
                }
                row(L("Parallelism")) {
                    presetMenu(
                        value: UInt64(draft.argonParallelism),
                        presets: [1, 2, 4, 8],
                        label: { L("\(Int($0)) threads") },
                        select: { draft.argonParallelism = UInt32($0) }
                    )
                }
            } else {
                row(L("Rounds")) {
                    presetMenu(
                        value: draft.aesRounds,
                        presets: [6_000_000, 30_000_000, 60_000_000, 120_000_000, 300_000_000],
                        label: { rounds in
                            rounds % 1_000_000 == 0 ? L("\(Int(rounds / 1_000_000)) million rounds") : L("\(Int(rounds)) rounds")
                        },
                        select: { draft.aesRounds = $0 }
                    )
                }
            }
            row(L("Time to unlock")) {
                Text(unlockSeconds.map { L("~\(String(format: "%.1f", max($0, 0.1))) s on this Mac") } ?? "…")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(KM.textSecondary)
                    .accessibilityIdentifier("dbSettings.unlockTime")
            }
            footer(note: L("Changing the cipher or key derivation re-encrypts the database when you apply.")) {
                saveButton(
                    busy == .encryption ? L("Re-encrypting…") : L("Apply Encryption"),
                    busy: .encryption,
                    enabled: encryptionDirty
                ) {
                    var settings = saved ?? draft
                    settings.cipher = draft.cipher
                    settings.kdf = draft.kdf
                    settings.argonMemoryMiB = draft.argonMemoryMiB
                    settings.argonIterations = draft.argonIterations
                    settings.argonParallelism = draft.argonParallelism
                    settings.aesRounds = draft.aesRounds
                    try await viewModel.updateDatabaseSettings(settings)
                    saved = settings
                    showToast(L("Database re-encrypted · \(settings.cipher.displayName) · \(settings.kdf.displayName)"))
                }
                .accessibilityIdentifier("dbSettings.applyEncryption")
            }
        }
    }

    /// Changes when any encryption setting changes, to measure the unlock time again.
    private var encryptionKey: String {
        "\(draft.kdf)-\(draft.argonMemoryMiB)-\(draft.argonIterations)-\(draft.argonParallelism)-\(draft.aesRounds)"
    }

    private var encryptionDirty: Bool {
        guard let saved else { return false }
        return saved.cipher != draft.cipher || saved.kdf != draft.kdf
            || saved.argonMemoryMiB != draft.argonMemoryMiB || saved.argonIterations != draft.argonIterations
            || saved.argonParallelism != draft.argonParallelism || saved.aesRounds != draft.aesRounds
    }

    private func presetMenu(value: UInt64, presets: [UInt64], label: @escaping (UInt64) -> String, select: @escaping (UInt64) -> Void) -> some View {
        // A value set elsewhere (another client, the old steppers) stays selectable.
        let options = presets.contains(value) ? presets : (presets + [value]).sorted()
        return Menu {
            ForEach(options, id: \.self) { option in
                Button(label(option)) { select(option) }
            }
        } label: {
            menuLabel(label(value))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: Recycle bin

    private var recycleBinCard: some View {
        card(L("Recycle Bin")) {
            row(
                L("Move deleted entries to the recycle bin"),
                subtitle: binEnabled ? L("Deleted entries can be restored") : L("Deleting is permanent"),
                isFirst: true
            ) {
                toggle(Binding(
                    get: { binEnabled },
                    set: { isOn in
                        if !isOn, status?.usesRecycleBin == true, (status?.recycleBinEntryCount ?? 0) > 0 {
                            askToTurnOffRecycleBin()
                        } else {
                            binEnabled = isOn
                        }
                    }
                ))
                .accessibilityIdentifier("dbSettings.recycleBin.enabled")
            }
            row(L("Recycle bin group"), subtitle: binCountLabel) {
                Menu {
                    if let path = status?.recycleBinPath {
                        Button(L("\(GroupPathFormatter.title(of: path)) — current")) { binGroup = "" }
                    }
                    ForEach(binGroupOptions, id: \.path) { group in
                        Button(String(repeating: "    ", count: group.depth) + group.title) { binGroup = group.path }
                    }
                    Divider()
                    Button(L("New Group…")) { binGroup = Self.newBinGroupTag }
                } label: {
                    menuLabel(binGroupTitle)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityIdentifier("dbSettings.recycleBin.group")
            }
            .opacity(binEnabled ? 1 : 0.45)
            .disabled(!binEnabled)
            footer {
                saveButton(L("Save Recycle Bin"), busy: .recycleBin, enabled: binDirty) {
                    let group: VaultRecycleBinGroup = binGroup.isEmpty
                        ? .current
                        : (binGroup == Self.newBinGroupTag ? .new(title: L("Recycle Bin")) : .existing(path: binGroup))
                    try await viewModel.updateRecycleBin(enabled: binEnabled, group: group, disposal: nil)
                    await reloadStatus()
                    showToast(L("Recycle bin settings saved"))
                }
                .accessibilityIdentifier("dbSettings.recycleBin.save")
            }
        }
    }

    private var binDirty: Bool {
        guard let status else { return false }
        return binEnabled != status.usesRecycleBin || (binEnabled && !binGroup.isEmpty)
    }

    private var binCountLabel: String {
        guard let status, status.usesRecycleBin else {
            return L("Off")
        }
        let count = status.recycleBinEntryCount
        return count == 0 ? L("Empty") : L("\(count) entries in the bin")
    }

    private var binGroupTitle: String {
        if binGroup == Self.newBinGroupTag {
            return L("New group “Recycle Bin”")
        }
        if !binGroup.isEmpty {
            return GroupPathFormatter.title(of: binGroup)
        }
        return status?.recycleBinPath.map { GroupPathFormatter.title(of: $0) } ?? L("Created on first delete")
    }

    /// Groups of the main database that can become the bin: not the root, not inside the current bin.
    private var binGroupOptions: [(path: String, title: String, depth: Int)] {
        guard case .loaded(let vault) = viewModel.loadState else {
            return []
        }
        let rootPath = vault.groups.first { !$0.path.contains(".") }?.path ?? ""
        let binPath = status?.recycleBinPath
        return vault.groups
            .filter { group in
                !group.isTrash && group.path != rootPath
                    && !(binPath.map { group.path == $0 || group.path.hasPrefix($0 + ".") } ?? false)
            }
            .map { ($0.path, $0.title, max($0.path.split(separator: ".").count - 2, 0)) }
    }

    private func askToTurnOffRecycleBin() {
        confirmRequest = ConfirmRequest(
            title: L("Turn off the recycle bin?"),
            message: L("The recycle bin has \(status?.recycleBinEntryCount ?? 0) entries."),
            confirmTitle: L("Empty Recycle Bin"),
            secondaryTitle: L("Keep as a Group"),
            secondaryAction: {
                confirmRequest = nil
                Task { await turnOffRecycleBin(.keepAsGroup) }
            }
        ) {
            confirmRequest = nil
            Task { await turnOffRecycleBin(.empty) }
        }
    }

    private func askToRemoveIcons() {
        confirmRequest = ConfirmRequest(
            title: L("Remove \(status?.unusedIconCount ?? 0) unused icons?"),
            message: L("Icons used by entries, groups or their history are kept."),
            confirmTitle: L("Remove")
        ) {
            confirmRequest = nil
            Task { await removeUnusedIcons() }
        }
    }

    private func turnOffRecycleBin(_ disposal: VaultRecycleBinDisposal) async {
        let count = status?.recycleBinEntryCount ?? 0
        await perform(.recycleBin) {
            try await viewModel.updateRecycleBin(enabled: false, group: .current, disposal: disposal)
            binEnabled = false
            binGroup = ""
            await reloadStatus()
            showToast(disposal == .empty
                ? L("Recycle bin emptied · \(count) entries deleted")
                : L("Recycle bin turned off · kept as a group"))
        }
    }

    // MARK: History

    private var historyCard: some View {
        card(L("History")) {
            row(L("Keep up to"), isFirst: true) {
                HStack(spacing: 10) {
                    HStack(spacing: 6) {
                        Button {
                            history.maxItems = max((history.maxItems ?? 10) - 1, 0)
                        } label: {
                            Image(systemName: "minus").font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(KMIconButtonStyle(size: 22, cornerRadius: 6, filled: true))
                        .accessibilityIdentifier("dbSettings.history.decrement")
                        Text(L("\(history.maxItems ?? 10) versions"))
                            .font(.system(size: 12).monospacedDigit())
                            .frame(minWidth: 72)
                            .accessibilityIdentifier("dbSettings.history.items")
                        Button {
                            history.maxItems = min((history.maxItems ?? 10) + 1, 9_999)
                        } label: {
                            Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(KMIconButtonStyle(size: 22, cornerRadius: 6, filled: true))
                        .accessibilityIdentifier("dbSettings.history.increment")
                    }
                    .opacity(history.maxItems == nil ? 0.45 : 1)
                    .disabled(history.maxItems == nil)
                    KMCheckbox(title: L("Unlimited"), isOn: Binding(
                        get: { history.maxItems == nil },
                        set: { history.maxItems = $0 ? nil : 10 }
                    ))
                    .accessibilityIdentifier("dbSettings.history.itemsUnlimited")
                }
            }
            row(L("Up to")) {
                HStack(spacing: 10) {
                    HStack(spacing: 6) {
                        TextField("", value: Binding(
                            get: { history.maxSizeMB ?? 6 },
                            set: { history.maxSizeMB = min(max($0, 1), 999) }
                        ), format: .number)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .font(.system(size: 12).monospacedDigit())
                        .frame(width: 40)
                        .kmField(height: 24)
                        .accessibilityIdentifier("dbSettings.history.size")
                        Text(L("MB per entry"))
                            .font(.system(size: 12))
                            .foregroundStyle(KM.textSecondary)
                    }
                    .opacity(history.maxSizeMB == nil ? 0.45 : 1)
                    .disabled(history.maxSizeMB == nil)
                    KMCheckbox(title: L("Unlimited"), isOn: Binding(
                        get: { history.maxSizeMB == nil },
                        set: { history.maxSizeMB = $0 ? nil : 6 }
                    ))
                    .accessibilityIdentifier("dbSettings.history.sizeUnlimited")
                }
            }
            footer(note: L("New limits apply when entries change; existing history isn’t trimmed.")) {
                saveButton(L("Save History"), busy: .history, enabled: history != status?.history) {
                    try await viewModel.updateHistoryLimits(history)
                    await reloadStatus()
                    showToast(L("History limits saved"))
                }
                .accessibilityIdentifier("dbSettings.history.save")
            }
        }
    }

    // MARK: Master key

    private var masterKeyCard: some View {
        card(L("Master Key")) {
            row(L("Password"), isFirst: true) {
                Text((status?.hasPassword ?? true) ? L("masterKey.password.set", default: "Set") : L("masterKey.password.notSet", default: "Not set"))
                    .font(.system(size: 12))
                    .foregroundStyle(KM.textSecondary)
            }
            row(L("Key file")) {
                Text(viewModel.selectedKeyFileURL?.lastPathComponent ?? L("None"))
                    .font(.system(size: 12))
                    .foregroundStyle(KM.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("dbSettings.keyFile")
            }
            row(L("Hardware key")) {
                Text(status?.hardwareKey?.shortLabel ?? L("None"))
                    .font(.system(size: 12))
                    .foregroundStyle(KM.textSecondary)
                    .accessibilityIdentifier("dbSettings.hardwareKey")
            }
            if status?.hardwareKey != nil {
                hardwareKeyTouchIDRow
            }
            row(L("Last changed")) {
                Text(status?.masterKeyChangedAt.map { RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date()) } ?? "—")
                    .font(.system(size: 12))
                    .foregroundStyle(KM.textSecondary)
            }
            footer {
                Button(L("Change Master Key…")) {
                    showsChangeMasterKey = true
                }
                .buttonStyle(KMButtonStyle(kind: .raised, height: 28, horizontalPadding: 14))
                .disabled(busy != nil)
                .accessibilityIdentifier("dbSettings.changeMasterKey")
            }
        }
    }

    private var hardwareKeyTouchIDRow: some View {
        let touchIDOn = viewModel.touchIDEnabledForSelectedVault
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Unlock with Touch ID without the hardware key"))
                    .font(.system(size: 13))
                Text(L("Your YubiKey response is stored in the keychain on this Mac. Off: the YubiKey is required every time."))
                    .font(.system(size: 11))
                    .foregroundStyle(KM.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !touchIDOn {
                    Label(L("Touch ID is off for this database. Turn it on in Settings → Security."), systemImage: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(KM.textSecondary)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            toggle(Binding(
                get: { touchIDOn && viewModel.touchIDSkipsHardwareKeyForSelectedVault },
                set: { skips in Task { await viewModel.setTouchIDSkipsHardwareKey(skips) } }
            ))
            .disabled(!touchIDOn)
            .accessibilityIdentifier("dbSettings.hardwareKeyTouchID")
        }
        .opacity(touchIDOn ? 1 : 0.6)
        .padding(.leading, 28)
        .padding(.trailing, 14)
        .padding(.vertical, 8)
    }

    // MARK: Maintenance

    private var maintenanceCard: some View {
        card(L("Maintenance")) {
            row(L("Unused custom icons"), subtitle: iconsSubtitle, isFirst: true) {
                if (status?.unusedIconCount ?? 0) > 0 {
                    Button(L("Remove…")) {
                        askToRemoveIcons()
                    }
                    .buttonStyle(KMButtonStyle(kind: .raised, height: 24, horizontalPadding: 12, fontWeight: .regular, fontSize: 12))
                    .disabled(busy != nil)
                    .accessibilityIdentifier("dbSettings.removeIcons")
                }
            }
        }
    }

    private var iconsSubtitle: String {
        guard let status, status.unusedIconCount > 0 else {
            return L("No unused icons")
        }
        let size = ByteCountFormatter.string(fromByteCount: Int64(status.unusedIconBytes), countStyle: .file)
        return L("\(status.unusedIconCount) icons") + " · " + size
    }

    private func removeUnusedIcons() async {
        let count = status?.unusedIconCount ?? 0
        await perform(.icons) {
            try await viewModel.removeUnusedCustomIcons()
            await reloadStatus()
            showToast(L("Removed \(count) unused icons"))
        }
    }

    // MARK: Additional databases

    private var additionalDatabasesCard: some View {
        card(L("Additional Databases")) {
            if viewModel.additionalDatabases.isEmpty {
                row(L("No additional databases"), isFirst: true) { EmptyView() }
            }
            ForEach(Array(viewModel.additionalDatabases.enumerated()), id: \.element.id) { index, database in
                row(database.name, subtitle: additionalSubtitle(database), isFirst: index == 0) {
                    HStack(spacing: 6) {
                        if database.state == .missing {
                            Button(L("Locate…")) { locate(database) }
                                .buttonStyle(KMButtonStyle(kind: .raised, height: 24, horizontalPadding: 10, fontWeight: .regular, fontSize: 12))
                        }
                        Button(L("Remove")) { viewModel.removeAdditionalDatabase(database.id) }
                            .buttonStyle(KMButtonStyle(kind: .raised, height: 24, horizontalPadding: 10, fontWeight: .regular, fontSize: 12))
                    }
                }
            }
            footer(note: L("Stored on this Mac only. Not saved in the database file.")) {
                Button(L("Add…")) {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        NotificationCenter.default.post(name: AppCommand.addAdditionalDatabase, object: nil)
                    }
                }
                .buttonStyle(KMButtonStyle(kind: .raised, height: 28, horizontalPadding: 14))
            }
        }
    }

    private func additionalSubtitle(_ database: AdditionalDatabase) -> String {
        if database.state == .missing {
            return L("File not found")
        }
        guard let keyFile = database.keyFileURL?.lastPathComponent else {
            return database.path
        }
        return database.path + " · " + L("Key file: \(keyFile)")
    }

    private func locate(_ database: AdditionalDatabase) {
        guard let url = chooseDatabaseFile(message: L("Find \(database.fileName)")) else {
            return
        }
        do {
            try viewModel.locateAdditionalDatabase(database.id, at: url)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: Building blocks

    private func card<Content: View>(_ title: String, @ViewBuilder rows: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .padding(.leading, 4)
            VStack(spacing: 0) {
                rows()
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(KM.insetFill))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color(light: .black(0.06), dark: .white(0.06)), lineWidth: 0.5)
            )
        }
    }

    private func row<Trailing: View>(
        _ title: String,
        subtitle: String? = nil,
        isFirst: Bool = false,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(KM.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(minHeight: 40)
        .overlay(alignment: .top) {
            if !isFirst {
                Rectangle().fill(KM.hairline).frame(height: 0.5).padding(.horizontal, 14)
            }
        }
    }

    /// The card's last row: an optional note and its action.
    private func footer<Action: View>(note: String? = nil, @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .center, spacing: 12) {
            if let note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(KM.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            action()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .top) {
            Rectangle().fill(KM.hairline).frame(height: 0.5).padding(.horizontal, 14)
        }
    }

    private func toggle(_ isOn: Binding<Bool>) -> some View {
        Toggle("", isOn: isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(KM.success)
    }

    private func menuLabel(_ title: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(KM.textSecondary)
        }
        .font(.system(size: 12))
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(KM.raisedButtonBackground))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(KM.softBorder, lineWidth: 0.5))
    }

    private func saveButton(_ title: String, busy card: Busy, enabled: Bool, action: @escaping () async throws -> Void) -> some View {
        Button {
            Task { await perform(card, action) }
        } label: {
            HStack(spacing: 6) {
                if busy == card {
                    ProgressView().controlSize(.mini)
                }
                Text(title)
            }
        }
        .buttonStyle(KMButtonStyle(kind: .primary, height: 28, horizontalPadding: 14, fontWeight: .semibold))
        .disabled(!enabled || busy != nil)
    }

    // MARK: Actions

    private func reload() async {
        do {
            let loaded = try await viewModel.loadDatabaseSettings()
            saved = loaded
            draft = loaded
            try await loadStatus()
            loadError = nil
            scheduleUnlockEstimate()
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? L("Could not load database settings.")
        }
    }

    /// Unsaved changes in other cards survive a refresh: drafts follow only when they matched the old status.
    private func loadStatus() async throws {
        let loaded = try await viewModel.loadMaintenanceStatus()
        let previous = status
        status = loaded
        if previous == nil || (binEnabled == previous?.usesRecycleBin && binGroup.isEmpty) {
            binEnabled = loaded.usesRecycleBin
            binGroup = ""
        }
        if previous == nil || history == previous?.history {
            history = loaded.history
        }
    }

    private func reloadStatus() async {
        try? await loadStatus()
    }

    /// Measures the KDF for the chosen settings; a newer choice cancels the wait and drops an older result.
    private func scheduleUnlockEstimate() {
        estimateTask?.cancel()
        guard saved != nil else {
            return
        }
        unlockSeconds = nil
        let settings = draft
        estimateTask = Task {
            // Wait for the user to stop clicking through the menus.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else {
                return
            }
            let seconds = await Task.detached(priority: .utility) {
                try? KeePassKitVaultLoader.estimatedUnlockSeconds(settings)
            }.value
            if !Task.isCancelled {
                unlockSeconds = seconds
            }
        }
    }

    private func perform(_ card: Busy?, _ action: () async throws -> Void) async {
        busy = card
        errorMessage = nil
        do {
            try await action()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? L("Operation failed.")
        }
        busy = nil
    }

    private func showToast(_ message: String) {
        withAnimation { toast = message }
        Task {
            try? await Task.sleep(for: .seconds(2.4))
            withAnimation {
                if toast == message {
                    toast = nil
                }
            }
        }
    }
}
