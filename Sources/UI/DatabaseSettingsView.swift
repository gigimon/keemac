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

public struct DatabaseSettingsView: View {
    /// Groups for the templates picker; nil hides it (KDBX 3.1 has no entry types).
    let templateGroups: [TemplateGroupOption]?
    let onLoad: @Sendable () async throws -> VaultDatabaseSettings
    let onSaveSettings: @Sendable (VaultDatabaseSettings) async throws -> Void
    let onChangePassword: @Sendable (String) async throws -> Void
    /// Databases attached to this one; nil hides the section.
    let additionalDatabases: [AdditionalDatabase]?
    let onRemoveAdditional: @MainActor (String) -> Void
    let onLocateAdditional: @MainActor (String, URL) throws -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var settings: VaultDatabaseSettings?
    @State private var loadError: String?
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var isBusy = false

    @State private var newPassword = ""
    @State private var confirmPassword = ""

    public init(
        templateGroups: [TemplateGroupOption]? = nil,
        onLoad: @escaping @Sendable () async throws -> VaultDatabaseSettings,
        onSaveSettings: @escaping @Sendable (VaultDatabaseSettings) async throws -> Void,
        onChangePassword: @escaping @Sendable (String) async throws -> Void,
        additionalDatabases: [AdditionalDatabase]? = nil,
        onRemoveAdditional: @escaping @MainActor (String) -> Void = { _ in },
        onLocateAdditional: @escaping @MainActor (String, URL) throws -> Void = { _, _ in }
    ) {
        self.templateGroups = templateGroups
        self.onLoad = onLoad
        self.onSaveSettings = onSaveSettings
        self.onChangePassword = onChangePassword
        self.additionalDatabases = additionalDatabases
        self.onRemoveAdditional = onRemoveAdditional
        self.onLocateAdditional = onLocateAdditional
    }

    public var body: some View {
        VStack(spacing: 0) {
            Text(L("Database Settings"))
                .font(.headline.weight(.semibold))
                .padding(.vertical, 10)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let loadError {
                        Text(loadError)
                            .foregroundStyle(.red)
                    } else if settings == nil {
                        ProgressView()
                            .frame(maxWidth: .infinity, alignment: .center)
                    } else {
                        generalSection
                        entryTypesSection
                        encryptionSection
                        passwordSection
                        additionalDatabasesSection
                    }

                    if let statusMessage {
                        Label(statusMessage, systemImage: "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.green)
                    }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
            }

            Divider()

            HStack {
                Spacer()
                Button(L("Close")) {
                    dismiss()
                }
                .keemacSecondaryActionButton(minWidth: 94)
                .disabled(isBusy)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 560, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await reload()
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var generalSection: some View {
        if let binding = settingsBinding {
            sectionCard(title: L("General")) {
                labeledField(L("Name")) {
                    TextField(L("Database name"), text: binding.name)
                        .textFieldStyle(.roundedBorder)
                }
                labeledField(L("Description")) {
                    TextField(L("Optional description"), text: binding.details, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)
                }
                saveButton(title: L("Save General")) {
                    try await onSaveSettings(current)
                }
            }
        }
    }

    @ViewBuilder
    private var entryTypesSection: some View {
        if let templateGroups, settings != nil {
            sectionCard(title: L("Entry Types")) {
                labeledField(L("Templates group")) {
                    Picker("", selection: Binding(
                        get: { current.templatesGroupPath ?? "" },
                        set: { path in
                            settings?.templatesGroupPath = path.isEmpty ? nil : path
                            Task { await perform { try await onSaveSettings(current) } }
                        }
                    )) {
                        Text(L("None")).tag("")
                        ForEach(templateGroups) { group in
                            Text(String(repeating: "    ", count: group.depth) + group.title).tag(group.path)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(isBusy)
                }
                Text(templatesSubtitle(templateGroups))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func templatesSubtitle(_ groups: [TemplateGroupOption]) -> String {
        guard let path = current.templatesGroupPath, let group = groups.first(where: { $0.path == path }) else {
            return L("New Entry offers only the built-in types.")
        }
        let count = group.entryCount
        return L("Entries in \(group.title) appear as types in New Entry: \(count).")
    }

    @ViewBuilder
    private var encryptionSection: some View {
        if let binding = settingsBinding {
            sectionCard(title: L("Encryption (Key Derivation)")) {
                Picker(L("Algorithm"), selection: binding.kdf) {
                    ForEach(VaultKDFAlgorithm.allCases, id: \.self) { algorithm in
                        Text(algorithm.displayName).tag(algorithm)
                    }
                }
                .pickerStyle(.segmented)

                if current.kdf.isArgon {
                    stepperRow(L("Iterations"), value: binding.argonIterations, range: 1...100, unit: "")
                    stepperRow(L("Memory"), value: binding.argonMemoryMiB, range: 1...1024, unit: L("MiB"), step: 8)
                    stepperRow32(L("Parallelism"), value: binding.argonParallelism, range: 1...16) { L("\($0) threads") }
                } else {
                    labeledField(L("Rounds")) {
                        TextField(L("Rounds"), value: binding.aesRounds, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 180)
                    }
                }

                Text(L("Higher values increase resistance to brute-force attacks but make unlocking slower."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                saveButton(title: L("Apply Encryption")) {
                    try await onSaveSettings(current)
                }
            }
        }
    }

    private var passwordSection: some View {
        sectionCard(title: L("Master Password")) {
            SecureField(L("New password"), text: $newPassword)
                .textFieldStyle(.roundedBorder)
            SecureField(L("Confirm new password"), text: $confirmPassword)
                .textFieldStyle(.roundedBorder)

            if let strength = PasswordStrength.evaluate(newPassword) {
                HStack(spacing: 8) {
                    Text(strength.level.label)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(strength.level.color)
                    Text(L("~\(Int(strength.entropyBits)) bits"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(L("Changing the master password re-encrypts and saves the database immediately. A .bak backup of the previous file is kept."))
                .font(.caption)
                .foregroundStyle(.secondary)

            saveButton(title: L("Change Password"), isDestructive: true) {
                guard newPassword == confirmPassword else {
                    throw DatabaseSettingsError.passwordMismatch
                }
                guard !newPassword.isEmpty else {
                    throw DatabaseSettingsError.emptyPassword
                }
                try await onChangePassword(newPassword)
                newPassword = ""
                confirmPassword = ""
            }
        }
    }

    // MARK: - Building blocks

    private var current: VaultDatabaseSettings {
        settings ?? VaultDatabaseSettings()
    }

    private var settingsBinding: Binding<VaultDatabaseSettings>? {
        guard settings != nil else {
            return nil
        }
        return Binding(
            get: { settings ?? VaultDatabaseSettings() },
            set: { settings = $0 }
        )
    }

    @ViewBuilder
    private var additionalDatabasesSection: some View {
        if let additionalDatabases {
            sectionCard(title: L("Additional Databases")) {
                if additionalDatabases.isEmpty {
                    Text(L("No additional databases"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(additionalDatabases) { database in
                    HStack(spacing: 10) {
                        Image(systemName: database.state == .missing ? "exclamationmark.triangle.fill" : "cylinder.split.1x2")
                            .foregroundStyle(database.state == .missing ? KM.warning : KM.accent)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(database.name)
                            Text(additionalSubtitle(database))
                                .font(.caption)
                                .foregroundStyle(database.state == .missing ? KM.warning : .secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 8)
                        if database.state == .missing {
                            Button(L("Locate…")) {
                                locate(database)
                            }
                            .keemacSecondaryActionButton()
                        }
                        Button(L("Remove")) {
                            onRemoveAdditional(database.id)
                        }
                        .keemacSecondaryActionButton()
                    }
                }
                HStack {
                    Button(L("Add…")) {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            NotificationCenter.default.post(name: AppCommand.addAdditionalDatabase, object: nil)
                        }
                    }
                    .keemacSecondaryActionButton()
                    Spacer()
                }
                Text(L("Stored on this Mac only. Not saved in the database file."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            try onLocateAdditional(database.id, url)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func sectionCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private func labeledField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func stepperRow(_ title: String, value: Binding<UInt64>, range: ClosedRange<Int>, unit: String, step: Int = 1) -> some View {
        let intBinding = Binding<Int>(
            get: { Int(value.wrappedValue) },
            set: { value.wrappedValue = UInt64(max($0, range.lowerBound)) }
        )
        return HStack {
            Text(title)
            Spacer()
            Text("\(intBinding.wrappedValue) \(unit)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Stepper("", value: intBinding, in: range, step: step)
                .labelsHidden()
        }
    }

    private func stepperRow32(_ title: String, value: Binding<UInt32>, range: ClosedRange<Int>, valueText: (Int) -> String) -> some View {
        let intBinding = Binding<Int>(
            get: { Int(value.wrappedValue) },
            set: { value.wrappedValue = UInt32(max($0, range.lowerBound)) }
        )
        return HStack {
            Text(title)
            Spacer()
            Text(valueText(intBinding.wrappedValue))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Stepper("", value: intBinding, in: range)
                .labelsHidden()
        }
    }

    private func saveButton(title: String, isDestructive: Bool = false, action: @escaping () async throws -> Void) -> some View {
        HStack {
            Spacer()
            Button {
                Task { await perform(action) }
            } label: {
                Text(title).frame(minWidth: 130)
            }
            .keemacPrimaryActionButton(minWidth: 130)
            .tint(isDestructive ? .red : .accentColor)
            .disabled(isBusy)
        }
    }

    // MARK: - Actions

    private func reload() async {
        do {
            let loaded = try await onLoad()
            settings = loaded
            loadError = nil
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? L("Could not load database settings.")
        }
    }

    private func perform(_ action: () async throws -> Void) async {
        isBusy = true
        statusMessage = nil
        errorMessage = nil
        do {
            try await action()
            statusMessage = L("Saved.")
        } catch let error as DatabaseSettingsError {
            errorMessage = error.message
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? L("Operation failed.")
        }
        isBusy = false
    }
}

private enum DatabaseSettingsError: Error {
    case passwordMismatch
    case emptyPassword

    var message: String {
        switch self {
        case .passwordMismatch: return L("Passwords do not match.")
        case .emptyPassword: return L("New password cannot be empty.")
        }
    }
}
