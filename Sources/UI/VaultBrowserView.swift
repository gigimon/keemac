import AppKit
import CryptoKit
import Data
import Domain
import SwiftUI

public struct VaultBrowserView: View {
    private struct GroupTreeNode: Identifiable, Hashable {
        let id: String
        let title: String
        let path: String
        let iconPNGData: Data?
        let iconID: Int?
        let children: [GroupTreeNode]?
    }

    public let vault: LoadedVault
    private let onCreateGroup: @Sendable (_ parentPath: String?, _ title: String, _ iconID: Int?) async throws -> Void
    private let onUpdateGroup: @Sendable (_ path: String, _ title: String, _ iconID: Int?) async throws -> Void
    private let onDeleteGroup: @Sendable (_ path: String) async throws -> Void
    private let onCreateEntry: @Sendable (_ groupPath: String?, _ form: VaultEntryForm) async throws -> Void
    private let onUpdateEntry: @Sendable (_ id: UUID, _ form: VaultEntryForm) async throws -> Void
    private let onDeleteEntry: @Sendable (_ id: UUID) async throws -> Void
    private let onLockVault: () -> Void

    @State private var searchText: String = ""
    @State private var selectedGroupPath: String?
    @State private var selectedEntryID: VaultEntry.ID?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var editorMode: EntryEditorMode?
    @State private var groupEditorMode: GroupEditorMode?
    @State private var deletingEntry: VaultEntry?
    @State private var deletingGroupPath: String?
    @State private var operationErrorMessage: String?
    @State private var isPerformingMutation: Bool = false

    public init(
        vault: LoadedVault,
        onCreateGroup: @escaping @Sendable (_ parentPath: String?, _ title: String, _ iconID: Int?) async throws -> Void,
        onUpdateGroup: @escaping @Sendable (_ path: String, _ title: String, _ iconID: Int?) async throws -> Void,
        onDeleteGroup: @escaping @Sendable (_ path: String) async throws -> Void,
        onCreateEntry: @escaping @Sendable (_ groupPath: String?, _ form: VaultEntryForm) async throws -> Void,
        onUpdateEntry: @escaping @Sendable (_ id: UUID, _ form: VaultEntryForm) async throws -> Void,
        onDeleteEntry: @escaping @Sendable (_ id: UUID) async throws -> Void,
        onLockVault: @escaping () -> Void
    ) {
        self.vault = vault
        self.onCreateGroup = onCreateGroup
        self.onUpdateGroup = onUpdateGroup
        self.onDeleteGroup = onDeleteGroup
        self.onCreateEntry = onCreateEntry
        self.onUpdateEntry = onUpdateEntry
        self.onDeleteEntry = onDeleteEntry
        self.onLockVault = onLockVault
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } content: {
            entriesList
                .navigationSplitViewColumnWidth(min: 300, ideal: 380, max: 520)
        } detail: {
            entryDetail
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                TextField("Search title, username, URL", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 340)
                    .controlSize(.regular)
            }

            ToolbarItem(placement: .primaryAction) {
                Button("Lock Vault") {
                    onLockVault()
                }
                .hoverHighlight()
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            ensureValidSelection()
        }
        .onChange(of: vault.summary.groupCount) { _, _ in
            ensureValidSelection()
        }
        .onChange(of: vault.summary.entryCount) { _, _ in
            ensureValidSelection()
        }
        .onChange(of: selectedGroupPath) { _, _ in
            ensureValidSelection()
        }
        .onChange(of: searchText) { _, _ in
            ensureValidSelection()
        }
        .sheet(item: $editorMode) { mode in
            VaultEntryEditorSheet(
                mode: mode,
                initialForm: mode.initialForm,
                isSaving: isPerformingMutation
            ) { form in
                await performEditorAction(mode: mode, form: form)
            }
        }
        .sheet(item: $groupEditorMode) { mode in
            GroupEditorSheet(mode: mode, isSaving: isPerformingMutation) { title, iconID in
                await performGroupEditorAction(mode: mode, title: title, iconID: iconID)
            }
        }
        .alert("Delete Group?", isPresented: Binding(get: {
            deletingGroupPath != nil
        }, set: { isPresented in
            if !isPresented {
                deletingGroupPath = nil
            }
        })) {
            Button("Delete", role: .destructive) {
                guard let deletingGroupPath else {
                    return
                }
                Task {
                    await performDeleteGroup(deletingGroupPath)
                }
            }
            .hoverHighlight(tint: .red)
            Button("Cancel", role: .cancel) {
                deletingGroupPath = nil
            }
            .hoverHighlight()
        } message: {
            Text("The selected group and all nested entries/subgroups will be moved to Trash or removed, depending on vault settings.")
        }
        .alert("Delete Entry?", isPresented: Binding(get: {
            deletingEntry != nil
        }, set: { isPresented in
            if !isPresented {
                deletingEntry = nil
            }
        })) {
            Button("Delete", role: .destructive) {
                guard let deletingEntry else {
                    return
                }
                Task {
                    await performDelete(deletingEntry.id)
                }
            }
            .hoverHighlight(tint: .red)
            Button("Cancel", role: .cancel) {
                deletingEntry = nil
            }
            .hoverHighlight()
        } message: {
            Text("This operation is saved immediately and cannot be undone in KeeMac.")
        }
        .alert("Save Error", isPresented: Binding(get: {
            operationErrorMessage != nil
        }, set: { isPresented in
            if !isPresented {
                operationErrorMessage = nil
            }
        })) {
            Button("OK", role: .cancel) {
                operationErrorMessage = nil
            }
            .hoverHighlight()
        } message: {
            Text(operationErrorMessage ?? "Unknown error")
        }
    }

    private var sidebar: some View {
        List(selection: $selectedGroupPath) {
            Text("All Entries")
                .tag(Optional<String>.none)
                .contextMenu {
                    Button("New Entry") {
                        editorMode = .create(groupPath: nil)
                    }

                    Divider()

                    Button("New Group") {
                        groupEditorMode = .create(parentPath: nil)
                    }
                }

            OutlineGroup(groupTree, children: \.children) { node in
                HStack(spacing: 8) {
                    EntryIconView(
                        iconPNGData: node.iconPNGData,
                        iconID: node.iconID,
                        size: 14,
                        fallbackSystemImage: "folder.fill"
                    )
                    Text(node.title)
                }
                .tag(Optional(node.path))
                .contextMenu {
                    Button("New Entry") {
                        editorMode = .create(groupPath: node.path)
                    }

                    Divider()

                    Button("New Subgroup") {
                        groupEditorMode = .create(parentPath: node.path)
                    }

                    Button("Edit Group") {
                        if let group = vault.groups.first(where: { $0.path == node.path }) {
                            groupEditorMode = .edit(path: group.path, title: group.title, iconID: group.iconID)
                        }
                    }

                    Divider()

                    Button("Delete Group", role: .destructive) {
                        deletingGroupPath = node.path
                    }
                }
            }
        }
        .navigationTitle("Groups")
    }

    private var entriesList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Entries")
                    .font(.title3.weight(.semibold))

                Spacer()

                Button {
                    editorMode = .create(groupPath: selectedGroupPath)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .help("New entry")
                .disabled(isPerformingMutation)
                .hoverHighlight()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            List(filteredEntries, selection: $selectedEntryID) { entry in
                HStack(alignment: .top, spacing: 10) {
                    EntryIconView(
                        iconPNGData: entry.iconPNGData,
                        iconID: entry.iconID,
                        size: 18,
                        fallbackSystemImage: "key.fill"
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.title)
                            .font(.headline)

                        HStack(spacing: 8) {
                            if let username = entry.username, !username.isEmpty {
                                Text(username)
                            }

                            if let host = entry.url?.host, !host.isEmpty {
                                Text(host)
                            }
                        }
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    }
                }
                .padding(.vertical, 4)
            }
            .overlay {
                if filteredEntries.isEmpty {
                    entriesEmptyState
                }
            }
        }
    }

    @ViewBuilder
    private var entryDetail: some View {
        if let entry = selectedEntry {
            VaultEntryDetailView(
                entry: entry,
                onEdit: isPerformingMutation ? nil : {
                    editorMode = .edit(entry: entry)
                },
                onDelete: isPerformingMutation ? nil : {
                    deletingEntry = entry
                }
            )
        } else {
            ContentUnavailableView(
                "Select an Entry",
                systemImage: "key.viewfinder",
                description: Text(filteredEntries.isEmpty ? "No entries match the current filter." : "Choose an entry from the list.")
            )
        }
    }

    private var selectedEntry: VaultEntry? {
        guard let selectedEntryID else {
            return filteredEntries.first
        }
        return filteredEntries.first(where: { $0.id == selectedEntryID })
    }

    private var filteredEntries: [VaultEntry] {
        let byGroup = vault.entries.filter { entry in
            guard let selectedGroupPath, !selectedGroupPath.isEmpty else {
                return true
            }
            return entry.groupPath == selectedGroupPath || entry.groupPath.hasPrefix("\(selectedGroupPath).")
        }
        .sorted { lhs, rhs in
            lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return byGroup
        }

        let normalizedQuery = query.lowercased()
        return byGroup.filter { entry in
            if entry.title.lowercased().contains(normalizedQuery) {
                return true
            }
            if let username = entry.username, username.lowercased().contains(normalizedQuery) {
                return true
            }
            if let urlText = entry.url?.absoluteString.lowercased(), urlText.contains(normalizedQuery) {
                return true
            }
            return false
        }
    }

    @ViewBuilder
    private var entriesEmptyState: some View {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView(
                "No Entries in Scope",
                systemImage: "tray",
                description: Text("The selected group does not contain entries.")
            )
        } else {
            ContentUnavailableView(
                "No Search Results",
                systemImage: "magnifyingglass",
                description: Text("Try a different title, username, or URL query.")
            )
        }
    }

    private var groupTree: [GroupTreeNode] {
        let groupIconsByPath = Dictionary(
            uniqueKeysWithValues: vault.groups
                .filter { !$0.path.isEmpty }
                .map { ($0.path, ($0.iconPNGData, $0.iconID)) }
        )
        return Self.buildGroupTree(from: Array(groupIconsByPath.keys), iconByPath: groupIconsByPath)
    }

    private func ensureValidSelection() {
        if let selectedGroupPath,
           !vault.groups.contains(where: { $0.path == selectedGroupPath }) {
            self.selectedGroupPath = nil
        }

        if let selectedEntryID, filteredEntries.contains(where: { $0.id == selectedEntryID }) {
            return
        }
        selectedEntryID = filteredEntries.first?.id
    }

    private func performEditorAction(mode: EntryEditorMode, form: VaultEntryForm) async {
        guard !isPerformingMutation else {
            return
        }
        isPerformingMutation = true
        defer { isPerformingMutation = false }

        do {
            switch mode {
            case .create(let groupPath):
                try await onCreateEntry(groupPath, form)
            case .edit(let entry):
                try await onUpdateEntry(entry.id, form)
            }
            editorMode = nil
        } catch {
            operationErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func performDelete(_ id: UUID) async {
        guard !isPerformingMutation else {
            return
        }
        isPerformingMutation = true
        defer { isPerformingMutation = false }

        do {
            try await onDeleteEntry(id)
            deletingEntry = nil
        } catch {
            operationErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func performGroupEditorAction(mode: GroupEditorMode, title: String, iconID: Int?) async {
        guard !isPerformingMutation else {
            return
        }
        isPerformingMutation = true
        defer { isPerformingMutation = false }

        do {
            switch mode {
            case .create(let parentPath):
                try await onCreateGroup(parentPath, title, iconID)
            case .edit(let path, _, _):
                try await onUpdateGroup(path, title, iconID)
                if selectedGroupPath == path {
                    selectedGroupPath = nil
                }
            }
            groupEditorMode = nil
        } catch {
            operationErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func performDeleteGroup(_ path: String) async {
        guard !isPerformingMutation else {
            return
        }
        isPerformingMutation = true
        defer { isPerformingMutation = false }

        do {
            try await onDeleteGroup(path)
            if selectedGroupPath == path {
                selectedGroupPath = nil
            }
            deletingGroupPath = nil
        } catch {
            operationErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private static func buildGroupTree(
        from paths: [String],
        iconByPath: [String: (pngData: Data?, iconID: Int?)]
    ) -> [GroupTreeNode] {
        final class Node {
            let title: String
            let path: String
            var iconPNGData: Data?
            var iconID: Int?
            var children: [String: Node] = [:]

            init(title: String, path: String, iconPNGData: Data? = nil, iconID: Int? = nil) {
                self.title = title
                self.path = path
                self.iconPNGData = iconPNGData
                self.iconID = iconID
            }
        }

        let root = Node(title: "", path: "")

        for path in paths.sorted() {
            let parts = path.split(separator: ".").map(String.init)
            guard !parts.isEmpty else {
                continue
            }

            var current = root
            var currentPath = ""

            for part in parts {
                currentPath = currentPath.isEmpty ? part : "\(currentPath).\(part)"
                if current.children[part] == nil {
                    let icon = iconByPath[currentPath]
                    current.children[part] = Node(
                        title: part,
                        path: currentPath,
                        iconPNGData: icon?.pngData ?? nil,
                        iconID: icon?.iconID ?? nil
                    )
                }
                if let next = current.children[part] {
                    let icon = iconByPath[currentPath]
                    if next.iconPNGData == nil {
                        next.iconPNGData = icon?.pngData ?? nil
                    }
                    if next.iconID == nil {
                        next.iconID = icon?.iconID ?? nil
                    }
                    current = next
                }
            }
        }

        func convert(_ node: Node) -> GroupTreeNode {
            let children = node.children.values
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                .map(convert)

            return GroupTreeNode(
                id: node.path,
                title: node.title,
                path: node.path,
                iconPNGData: node.iconPNGData,
                iconID: node.iconID,
                children: children.isEmpty ? nil : children
            )
        }

        return root.children.values
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            .map(convert)
    }
}

private enum GroupEditorMode: Identifiable {
    case create(parentPath: String?)
    case edit(path: String, title: String, iconID: Int?)

    var id: String {
        switch self {
        case .create(let parentPath):
            return "create-group:\(parentPath ?? "root")"
        case .edit(let path, _, _):
            return "edit-group:\(path)"
        }
    }

    var title: String {
        switch self {
        case .create:
            return "New Group"
        case .edit:
            return "Edit Group"
        }
    }

    var parentPath: String? {
        switch self {
        case .create(let parentPath):
            return parentPath
        case .edit(let path, _, _):
            let components = path.split(separator: ".").map(String.init)
            guard components.count > 1 else {
                return nil
            }
            return components.dropLast().joined(separator: ".")
        }
    }

    var submitTitle: String {
        switch self {
        case .create:
            return "Create"
        case .edit:
            return "Save"
        }
    }

    var initialTitle: String {
        switch self {
        case .create:
            return ""
        case .edit(_, let title, _):
            return title
        }
    }

    var initialIconID: Int? {
        switch self {
        case .create:
            return nil
        case .edit(_, _, let iconID):
            return iconID
        }
    }

    var targetPath: String? {
        switch self {
        case .create:
            return nil
        case .edit(let path, _, _):
            return path
        }
    }
}

private enum EntryEditorMode: Identifiable {
    case create(groupPath: String?)
    case edit(entry: VaultEntry)

    var id: String {
        switch self {
        case .create(let groupPath):
            return "create:\(groupPath ?? "root")"
        case .edit(let entry):
            return "edit:\(entry.id.uuidString)"
        }
    }

    var title: String {
        switch self {
        case .create:
            return "New Entry"
        case .edit:
            return "Edit Entry"
        }
    }

    var submitTitle: String {
        switch self {
        case .create:
            return "Create"
        case .edit:
            return "Save"
        }
    }

    var initialForm: VaultEntryForm {
        switch self {
        case .create:
            return VaultEntryForm(title: "")
        case .edit(let entry):
            let customFields = entry.customFields.map {
                VaultCustomFieldForm(
                    key: $0.key,
                    value: $0.value,
                    isProtected: $0.isProtected
                )
            }

            let otpForm: VaultOTPForm?
            if let otp = entry.otp {
                otpForm = VaultOTPForm(
                    secret: OTPSecretFormatter.encodeBase32(otp.secret),
                    digits: otp.digits,
                    period: otp.period,
                    algorithm: otp.algorithm,
                    storageStyle: entry.otpStorageStyle ?? .otpAuth
                )
            } else {
                otpForm = nil
            }

            return VaultEntryForm(
                title: entry.title,
                username: entry.username ?? "",
                password: entry.password ?? "",
                url: entry.url?.absoluteString ?? "",
                notes: entry.notes ?? "",
                iconID: entry.iconID,
                customFields: customFields,
                otp: otpForm
            )
        }
    }
}

private struct GroupEditorSheet: View {
    let mode: GroupEditorMode
    let isSaving: Bool
    let onSubmit: @Sendable (String, Int?) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var iconID: Int?
    @State private var validationMessage: String?

    init(mode: GroupEditorMode, isSaving: Bool, onSubmit: @escaping @Sendable (String, Int?) async -> Void) {
        self.mode = mode
        self.isSaving = isSaving
        self.onSubmit = onSubmit
        _title = State(initialValue: mode.initialTitle)
        _iconID = State(initialValue: mode.initialIconID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(mode.title)
                .font(.title3.weight(.semibold))

            if let parentPath = mode.parentPath, !parentPath.isEmpty {
                LabeledContent("Parent") {
                    Text(parentPath)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                LabeledContent("Parent") {
                    Text("Root")
                        .foregroundStyle(.secondary)
                }
            }

            if let targetPath = mode.targetPath {
                LabeledContent("Path") {
                    Text(targetPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            TextField("Group title", text: $title)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    submit()
                }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    EntryIconView(
                        iconPNGData: nil,
                        iconID: iconID,
                        size: 20,
                        fallbackSystemImage: "folder.fill"
                    )
                    Text(iconID.map { "Icon \($0)" } ?? "Default icon")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Default") {
                        iconID = nil
                    }
                    .disabled(iconID == nil)
                    .hoverHighlight()
                }

                IconPalettePicker(selectedIconID: $iconID)
                    .frame(maxHeight: 120)
            }

            if let validationMessage {
                Text(validationMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .disabled(isSaving)
                .hoverHighlight()

                Spacer()

                Button(mode.submitTitle) {
                    submit()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving)
                .hoverHighlight()
            }
        }
        .padding(18)
        .frame(minWidth: 420)
    }

    private func submit() {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else {
            validationMessage = "Group title is required."
            return
        }

        validationMessage = nil
        Task {
            await onSubmit(normalizedTitle, iconID)
        }
    }
}

private struct VaultEntryEditorSheet: View {
    let mode: EntryEditorMode
    let initialForm: VaultEntryForm
    let isSaving: Bool
    let onSubmit: @Sendable (VaultEntryForm) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var form: VaultEntryForm
    @State private var validationMessage: String?
    @State private var otpEnabled: Bool
    @State private var revealPassword: Bool = false
    @State private var showPasswordGenerator: Bool = false
    @State private var passwordGeneratorOptions = PasswordGenerator.Options()

    init(
        mode: EntryEditorMode,
        initialForm: VaultEntryForm,
        isSaving: Bool,
        onSubmit: @escaping @Sendable (VaultEntryForm) async -> Void
    ) {
        self.mode = mode
        self.initialForm = initialForm
        self.isSaving = isSaving
        self.onSubmit = onSubmit
        _form = State(initialValue: initialForm)
        _otpEnabled = State(initialValue: initialForm.otp != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Basic") {
                    TextField("Title", text: $form.title)
                    TextField("Username", text: $form.username)
                    passwordField
                    TextField("URL", text: $form.url)
                    TextField("Notes", text: $form.notes, axis: .vertical)
                        .lineLimit(3...6)
                }

                Section("Icon") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            EntryIconView(
                                iconPNGData: nil,
                                iconID: form.iconID,
                                size: 20,
                                fallbackSystemImage: "key.fill"
                            )
                            Text(form.iconID.map { "Icon \($0)" } ?? "Default icon")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Default") {
                                form.iconID = nil
                            }
                            .disabled(form.iconID == nil)
                            .hoverHighlight()
                        }

                        IconPalettePicker(selectedIconID: $form.iconID)
                    }
                }

                Section("Custom Fields") {
                    if form.customFields.isEmpty {
                        Text("No custom fields")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach($form.customFields) { $field in
                            VStack(alignment: .leading, spacing: 6) {
                                TextField("Key", text: $field.key)
                                TextField("Value", text: $field.value)
                                Toggle("Protected", isOn: $field.isProtected)
                                Button("Remove Field", role: .destructive) {
                                    form.customFields.removeAll(where: { $0.id == field.id })
                                }
                                .hoverHighlight(tint: .red)
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    Button("Add Custom Field") {
                        form.customFields.append(
                            VaultCustomFieldForm(key: "", value: "", isProtected: false)
                        )
                    }
                    .hoverHighlight()
                }

                Section("OTP") {
                    Toggle("Enable OTP", isOn: $otpEnabled)
                        .onChange(of: otpEnabled) { _, enabled in
                            if enabled {
                                form.otp = form.otp ?? VaultOTPForm(secret: "")
                            } else {
                                form.otp = nil
                            }
                        }

                    if otpEnabled {
                        if form.otp == nil {
                            Text("Configure OTP fields")
                                .foregroundStyle(.secondary)
                        } else {
                            TextField("Secret (Base32/Base64/Hex)", text: Binding(
                                get: { form.otp?.secret ?? "" },
                                set: { form.otp?.secret = $0 }
                            ))

                            Picker("Algorithm", selection: Binding(
                                get: { form.otp?.algorithm ?? .sha1 },
                                set: { form.otp?.algorithm = $0 }
                            )) {
                                Text("SHA1").tag(VaultOTPAlgorithm.sha1)
                                Text("SHA256").tag(VaultOTPAlgorithm.sha256)
                                Text("SHA512").tag(VaultOTPAlgorithm.sha512)
                            }

                            Picker("Storage", selection: Binding(
                                get: { form.otp?.storageStyle ?? .otpAuth },
                                set: { form.otp?.storageStyle = $0 }
                            )) {
                                Text("otpauth URL").tag(VaultOTPStorageStyle.otpAuth)
                                Text("Native TimeOTP").tag(VaultOTPStorageStyle.native)
                            }

                            Stepper(
                                "Digits: \(form.otp?.digits ?? 6)",
                                value: Binding(
                                    get: { form.otp?.digits ?? 6 },
                                    set: { form.otp?.digits = $0 }
                                ),
                                in: 6...9
                            )
                            Stepper(
                                "Period: \(form.otp?.period ?? 30)s",
                                value: Binding(
                                    get: { form.otp?.period ?? 30 },
                                    set: { form.otp?.period = $0 }
                                ),
                                in: 1...120
                            )
                        }
                    }
                }
            }
            .formStyle(.grouped)

            if let validationMessage {
                Text(validationMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .disabled(isSaving)
                .hoverHighlight()

                Spacer()

                Button(mode.submitTitle) {
                    submit()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving)
                .hoverHighlight()
            }
            .padding(16)
        }
        .frame(minWidth: 560, minHeight: 580)
        .navigationTitle(mode.title)
    }

    private var passwordField: some View {
        HStack(spacing: 8) {
            Group {
                if revealPassword {
                    TextField("Password", text: $form.password)
                        .textFieldStyle(.roundedBorder)
                } else {
                    SecureField("Password", text: $form.password)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Button {
                revealPassword.toggle()
            } label: {
                Image(systemName: revealPassword ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .help(revealPassword ? "Hide password" : "Reveal password")
            .hoverHighlight()

            Button {
                showPasswordGenerator = true
            } label: {
                Image(systemName: "dice")
            }
            .buttonStyle(.borderless)
            .help("Generate password")
            .hoverHighlight()
            .popover(isPresented: $showPasswordGenerator, arrowEdge: .bottom) {
                PasswordGeneratorPopover(
                    options: $passwordGeneratorOptions,
                    onGenerate: {
                        form.password = PasswordGenerator.makePassword(options: passwordGeneratorOptions)
                        revealPassword = false
                    }
                )
            }
        }
    }

    private func submit() {
        validationMessage = validate(form: form, otpEnabled: otpEnabled)
        guard validationMessage == nil else {
            return
        }

        if !otpEnabled {
            form.otp = nil
        }

        let formToSubmit = form
        Task {
            await onSubmit(formToSubmit)
        }
    }

    private func validate(form: VaultEntryForm, otpEnabled: Bool) -> String? {
        if form.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Title is required."
        }

        var keySet = Set<String>()
        for field in form.customFields {
            let trimmedKey = field.key.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedKey.isEmpty {
                return "Custom field key cannot be empty."
            }
            let normalized = trimmedKey.lowercased()
            if keySet.contains(normalized) {
                return "Custom field keys must be unique."
            }
            keySet.insert(normalized)
        }

        if otpEnabled {
            guard let otp = form.otp else {
                return "OTP configuration is incomplete."
            }
            if otp.secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "OTP secret is required."
            }
            if otp.digits < 6 || otp.digits > 9 {
                return "OTP digits must be between 6 and 9."
            }
            if otp.period < 1 {
                return "OTP period must be positive."
            }
        }

        return nil
    }
}

private struct VaultEntryDetailView: View {
    let entry: VaultEntry
    let onEdit: (() -> Void)?
    let onDelete: (() -> Void)?
    @State private var revealPassword: Bool = false
    @State private var now: Date = .now
    private let otpTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    EntryIconView(
                        iconPNGData: entry.iconPNGData,
                        iconID: entry.iconID,
                        size: 28,
                        fallbackSystemImage: "key.fill"
                    )
                    Text(entry.title)
                        .font(.title2.bold())

                    Spacer()

                    if let onEdit {
                        IconActionButton(systemImage: "pencil", helpText: "Edit entry", action: onEdit)
                    }
                    if let onDelete {
                        IconActionButton(systemImage: "trash", helpText: "Delete entry", tint: .red, action: onDelete)
                    }
                }

                metadata
                credentials
                notes
                customFields
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Entry")
        .onReceive(otpTimer) { value in
            now = value
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Group")
                .font(.headline)
            Text(entry.groupPath.isEmpty ? "-" : entry.groupPath)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    private var credentials: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Credentials")
                .font(.headline)

            HStack {
                Text("Username")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 100, alignment: .leading)
                Text(entry.username ?? "-")
                    .textSelection(.enabled)
                Spacer()
                if let username = entry.username, !username.isEmpty {
                    IconActionButton(systemImage: "doc.on.doc", helpText: "Copy username") {
                        copyToClipboard(username)
                    }
                }
            }

            HStack {
                Text("Password")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 100, alignment: .leading)

                if revealPassword {
                    Text(displayPassword)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                } else {
                    Text(displayPassword)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.disabled)
                }

                Spacer()

                if entry.password != nil {
                    IconActionButton(
                        systemImage: revealPassword ? "eye.slash" : "eye",
                        helpText: revealPassword ? "Hide password" : "Reveal password"
                    ) {
                        revealPassword.toggle()
                    }

                    if let password = entry.password, !password.isEmpty {
                        IconActionButton(systemImage: "doc.on.doc", helpText: "Copy password") {
                            copyToClipboard(password)
                        }
                    }
                }
            }

            HStack {
                Text("URL")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 100, alignment: .leading)
                if let url = entry.url {
                    Link(url.absoluteString, destination: url)
                        .textSelection(.enabled)
                } else {
                    Text("-")
                }
            }

            if let otpState {
                HStack {
                    Text("OTP")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 100, alignment: .leading)

                    Text(otpState.code)
                        .font(.system(.title3, design: .monospaced))
                        .fontWeight(.semibold)
                        .textSelection(.enabled)

                    Spacer()

                    IconActionButton(systemImage: "doc.on.doc", helpText: "Copy OTP code") {
                        copyToClipboard(otpState.code)
                    }
                }

                HStack(spacing: 10) {
                    Text("Expires in")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 100, alignment: .leading)

                    Text("\(otpState.remainingSeconds)s")
                        .font(.callout.monospaced())

                    ProgressView(
                        value: Double(otpState.period - otpState.remainingSeconds),
                        total: Double(otpState.period)
                    )
                    .frame(width: 180)

                    Spacer()
                }
            }
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notes")
                .font(.headline)
            Text(entry.notes?.isEmpty == false ? entry.notes! : "-")
                .textSelection(.enabled)
                .foregroundStyle(entry.notes?.isEmpty == false ? .primary : .secondary)
        }
    }

    @ViewBuilder
    private var customFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Custom Fields")
                .font(.headline)

            if entry.customFields.isEmpty {
                Text("-")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(entry.customFields.enumerated()), id: \.element.id) { _, field in
                    HStack(alignment: .top, spacing: 8) {
                        Text(field.key)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(width: 140, alignment: .leading)

                        if field.isProtected {
                            Text("••••••")
                                .textSelection(.disabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text(field.value)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
    }

    private var displayPassword: String {
        guard let password = entry.password, !password.isEmpty else {
            return "-"
        }
        if revealPassword {
            return password
        }
        return String(repeating: "•", count: max(password.count, 8))
    }

    private var otpState: OTPCodeState? {
        guard let otp = entry.otp else {
            return nil
        }
        return OTPCodeGenerator.makeCodeState(from: otp, now: now)
    }

    private func copyToClipboard(_ value: String) {
        SensitiveClipboard.shared.copySensitiveText(value)
    }
}

private struct IconActionButton: View {
    let systemImage: String
    let helpText: String
    let tint: Color?
    let action: () -> Void

    init(systemImage: String, helpText: String, tint: Color? = nil, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.helpText = helpText
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .foregroundStyle(tint ?? .primary)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .help(helpText)
        .hoverHighlight()
    }
}

private struct IconPalettePicker: View {
    @Binding var selectedIconID: Int?

    private let columns = [
        GridItem(.adaptive(minimum: 30, maximum: 30), spacing: 6)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(DefaultKeePassIconMapper.availableIconIDs, id: \.self) { iconID in
                    Button {
                        selectedIconID = iconID
                    } label: {
                        Image(systemName: DefaultKeePassIconMapper.symbolName(for: iconID) ?? "questionmark")
                            .frame(width: 18, height: 18)
                            .padding(6)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(selectedIconID == iconID ? Color.accentColor.opacity(0.22) : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(selectedIconID == iconID ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Icon \(iconID)")
                    .hoverHighlight()
                }
            }
            .padding(.vertical, 4)
        }
        .frame(minHeight: 96, maxHeight: 144)
    }
}

private struct PasswordGeneratorPopover: View {
    @Binding var options: PasswordGenerator.Options
    let onGenerate: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Password Generator")
                .font(.headline)

            Stepper("Length: \(options.length)", value: $options.length, in: 8...128)

            Toggle("Lowercase (a-z)", isOn: $options.includeLowercase)
            Toggle("Uppercase (A-Z)", isOn: $options.includeUppercase)
            Toggle("Digits (0-9)", isOn: $options.includeDigits)
            Toggle("Symbols (!@#...)", isOn: $options.includeSymbols)

            if !options.hasAnyCharacterSet {
                Text("Select at least one character set.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Close") {
                    dismiss()
                }
                .hoverHighlight()

                Spacer()

                Button("Generate") {
                    onGenerate()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!options.hasAnyCharacterSet)
                .hoverHighlight()
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}

private enum PasswordGenerator {
    struct Options: Equatable {
        var length: Int = 20
        var includeLowercase: Bool = true
        var includeUppercase: Bool = true
        var includeDigits: Bool = true
        var includeSymbols: Bool = true

        var hasAnyCharacterSet: Bool {
            includeLowercase || includeUppercase || includeDigits || includeSymbols
        }
    }

    private static let lowercase = Array("abcdefghijklmnopqrstuvwxyz")
    private static let uppercase = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    private static let digits = Array("0123456789")
    private static let symbols = Array("!@#$%^&*()-_=+[]{};:,.?/")

    static func makePassword(options: Options) -> String {
        var activeSets: [[Character]] = []
        if options.includeLowercase {
            activeSets.append(lowercase)
        }
        if options.includeUppercase {
            activeSets.append(uppercase)
        }
        if options.includeDigits {
            activeSets.append(digits)
        }
        if options.includeSymbols {
            activeSets.append(symbols)
        }

        if activeSets.isEmpty {
            activeSets = [lowercase]
        }

        let targetLength = max(options.length, activeSets.count)
        let fullSet = activeSets.flatMap { $0 }
        var rng = SystemRandomNumberGenerator()
        var result: [Character] = activeSets.compactMap { $0.randomElement(using: &rng) }

        while result.count < targetLength {
            if let next = fullSet.randomElement(using: &rng) {
                result.append(next)
            }
        }

        result.shuffle(using: &rng)
        return String(result)
    }
}

private struct EntryIconView: View {
    let iconPNGData: Data?
    let iconID: Int?
    let size: CGFloat
    let fallbackSystemImage: String

    var body: some View {
        Group {
            if let iconPNGData, let image = NSImage(data: iconPNGData) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
            } else {
                Image(systemName: DefaultKeePassIconMapper.symbolName(for: iconID) ?? fallbackSystemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
            }
        }
    }
}

private enum DefaultKeePassIconMapper {
    static let availableIconIDs = Array(0...68)

    static func symbolName(for iconID: Int?) -> String? {
        guard let iconID else {
            return nil
        }

        switch iconID {
        case 0: return "key.fill"
        case 1: return "network"
        case 2: return "exclamationmark.triangle.fill"
        case 3: return "server.rack"
        case 4: return "paperclip"
        case 5: return "globe"
        case 6: return "externaldrive.fill.badge.minus"
        case 7: return "note.text"
        case 8: return "dot.radiowaves.left.and.right"
        case 9: return "person.crop.circle"
        case 10: return "person.2.fill"
        case 11: return "camera.fill"
        case 12: return "desktopcomputer.trianglebadge.exclamationmark"
        case 13: return "key.horizontal.fill"
        case 14: return "battery.100"
        case 15: return "scanner.fill"
        case 16: return "safari.fill"
        case 17: return "opticaldiscdrive.fill"
        case 18: return "display"
        case 19: return "envelope.fill"
        case 20: return "ellipsis.circle.fill"
        case 21: return "calendar"
        case 22: return "textformat.abc"
        case 23: return "square.grid.3x3.fill"
        case 24: return "link"
        case 25: return "tray.fill"
        case 26: return "square.and.arrow.down.fill"
        case 27: return "externaldrive.fill.badge.minus"
        case 28: return "play.rectangle.fill"
        case 29: return "terminal.fill"
        case 30: return "terminal"
        case 31: return "printer.fill"
        case 32: return "externaldrive.connected.to.line.below.fill"
        case 33: return "play.fill"
        case 34: return "gearshape.fill"
        case 35: return "macwindow"
        case 36: return "archivebox.fill"
        case 37: return "percent"
        case 38: return "network.slash"
        case 39: return "clock.arrow.circlepath"
        case 40: return "envelope.badge.magnifyingglass"
        case 41: return "point.topleft.down.curvedto.point.bottomright.up"
        case 42: return "memorychip.fill"
        case 43: return "trash.fill"
        case 44: return "note.text"
        case 45: return "xmark.circle.fill"
        case 46: return "questionmark.circle.fill"
        case 47: return "shippingbox.fill"
        case 48: return "folder.fill"
        case 49: return "folder"
        case 50: return "archivebox.circle.fill"
        case 51: return "lock.open.fill"
        case 52: return "lock.fill"
        case 53: return "checkmark.circle.fill"
        case 54: return "signature"
        case 55: return "photo.fill"
        case 56: return "book.closed.fill"
        case 57: return "doc.text.fill"
        case 58: return "person.badge.shield.checkmark.fill"
        case 59: return "hammer.fill"
        case 60: return "house.fill"
        case 61: return "square.3.layers.3d.down.right.fill"
        case 62: return "lizard.fill"
        case 63: return "feather.fill"
        case 64: return "apple.logo"
        case 65: return "text.book.closed.fill"
        case 66: return "dollarsign.circle.fill"
        case 67: return "checkmark.seal.fill"
        case 68: return "phone.fill"
        default: return nil
        }
    }
}

private struct OTPCodeState {
    let code: String
    let remainingSeconds: Int
    let period: Int
}

private enum OTPCodeGenerator {
    static func makeCodeState(from config: VaultOTPConfiguration, now: Date) -> OTPCodeState? {
        let period = max(config.period, 1)
        let seconds = now.timeIntervalSince1970 - config.timeBase
        guard seconds >= 0 else {
            return nil
        }

        let counter = UInt64(floor(seconds / Double(period)))
        let counterData = counter.bigEndianData
        let hash = hmac(
            secret: config.secret,
            data: counterData,
            algorithm: config.algorithm
        )

        guard hash.count >= 20 else {
            return nil
        }

        let offset = Int(hash[hash.count - 1] & 0x0f)
        guard hash.count > offset + 3 else {
            return nil
        }

        let codeInt =
            (Int(hash[offset] & 0x7f) << 24) |
            (Int(hash[offset + 1]) << 16) |
            (Int(hash[offset + 2]) << 8) |
            Int(hash[offset + 3])
        let modulo = decimalModulo(digits: config.digits)
        guard modulo > 0 else {
            return nil
        }

        let code = String(codeInt % modulo).leftPadded(to: config.digits, with: "0")

        let elapsed = Int(floor(seconds))
        let remainder = elapsed % period
        let remaining = remainder == 0 ? period : (period - remainder)

        return OTPCodeState(code: code, remainingSeconds: remaining, period: period)
    }

    private static func hmac(secret: Data, data: Data, algorithm: VaultOTPAlgorithm) -> Data {
        let key = SymmetricKey(data: secret)
        switch algorithm {
        case .sha1:
            return Data(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: key))
        case .sha256:
            return Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
        case .sha512:
            return Data(HMAC<SHA512>.authenticationCode(for: data, using: key))
        }
    }

    private static func decimalModulo(digits: Int) -> Int {
        let clampedDigits = min(max(digits, 1), 9)
        var value = 1
        for _ in 0..<clampedDigits {
            value *= 10
        }
        return value
    }
}

private extension UInt64 {
    var bigEndianData: Data {
        var value = self.bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}

private extension String {
    func leftPadded(to length: Int, with character: Character) -> String {
        guard count < length else {
            return self
        }
        return String(repeating: String(character), count: length - count) + self
    }
}

private enum OTPSecretFormatter {
    static func encodeBase32(_ data: Data) -> String {
        guard !data.isEmpty else {
            return ""
        }

        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var output = ""
        var buffer: UInt32 = 0
        var bitsLeft = 0

        for byte in data {
            buffer = (buffer << 8) | UInt32(byte)
            bitsLeft += 8

            while bitsLeft >= 5 {
                let index = Int((buffer >> UInt32(bitsLeft - 5)) & 0x1f)
                output.append(alphabet[index])
                bitsLeft -= 5
            }
        }

        if bitsLeft > 0 {
            let index = Int((buffer << UInt32(5 - bitsLeft)) & 0x1f)
            output.append(alphabet[index])
        }

        return output
    }
}
