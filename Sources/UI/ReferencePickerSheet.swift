import Domain
import SwiftUI

extension VaultFieldReference.Field {
    var title: String {
        switch self {
        case .title: return L("Title")
        case .username: return L("Username")
        case .password: return L("Password")
        case .url: return L("URL")
        case .notes: return L("Notes")
        }
    }
}

/// "Insert Reference": pick another entry and one of its fields; the edited field then mirrors it.
struct ReferencePickerSheet: View {
    let entries: [VaultEntry]
    /// The entry being edited; it and entries that link back to it can't be picked.
    let currentEntryID: UUID
    let currentTitle: String
    /// The field the reference goes into.
    let targetField: VaultFieldReference.Field
    let onInsert: (VaultFieldReference) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selectedID: UUID?
    @State private var sourceField: VaultFieldReference.Field?
    @State private var revealsPassword = false
    @FocusState private var isSearchFocused: Bool

    init(
        entries: [VaultEntry],
        currentEntryID: UUID,
        currentTitle: String,
        targetField: VaultFieldReference.Field,
        initial: VaultFieldReference? = nil,
        onInsert: @escaping (VaultFieldReference) -> Void
    ) {
        self.entries = entries
        self.currentEntryID = currentEntryID
        self.currentTitle = currentTitle
        self.targetField = targetField
        self.onInsert = onInsert
        _selectedID = State(initialValue: initial?.entryID)
        _sourceField = State(initialValue: initial?.field)
    }

    private var source: VaultEntry? {
        selectedID.flatMap { id in entries.first { $0.id == id && !$0.isTrashed } }
    }

    private var candidates: [VaultEntry] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return entries
            .filter { !$0.isTrashed && $0.id != currentEntryID }
            .filter { entry in
                needle.isEmpty || [entry.title, entry.username ?? "", entry.url?.absoluteString ?? ""]
                    .contains { $0.lowercased().contains(needle) }
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private var canInsert: Bool {
        guard let source, let sourceField else {
            return false
        }
        return !source.value(of: sourceField).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("Insert Reference"))
                .font(.system(size: 15, weight: .bold))
            Text(L("Into \(targetField.title) of “\(currentTitle)”"))
                .font(.system(size: 11))
                .foregroundStyle(KM.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if let source {
                chosen(source)
            } else {
                picker
            }

            HStack(spacing: 8) {
                Text(summary)
                    .font(.system(size: 12))
                    .foregroundStyle(KM.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(L("Cancel")) {
                    dismiss()
                }
                .buttonStyle(KMButtonStyle(kind: .secondary, height: 30))
                .keyboardShortcut(.cancelAction)
                Button(L("Insert"), action: insert)
                    .buttonStyle(KMButtonStyle(kind: .primary, height: 30, horizontalPadding: 18, fontWeight: .semibold))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canInsert)
            }
            .padding(.top, 16)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .frame(width: 420)
        .background(KM.sheetBackground)
    }

    // MARK: - Picking an entry

    private var picker: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(KM.textSecondary)
                TextField(L("Search entries"), text: $query)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(KM.subtleFill))
            .padding(.top, 14)
            .onAppear {
                isSearchFocused = true
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(candidates) { entry in
                        entryRow(entry)
                    }
                }
                .padding(.horizontal, -8)
                if candidates.isEmpty {
                    Text(query.isEmpty ? L("No other entries") : L("No entries match “\(query.trimmingCharacters(in: .whitespaces))”"))
                        .font(.system(size: 13))
                        .foregroundStyle(KM.textSecondary)
                        .padding(.top, 90)
                }
            }
            .frame(height: 264)
            .padding(.top, 10)
        }
    }

    private func entryRow(_ entry: VaultEntry) -> some View {
        let linksBack = entry.references(currentEntryID, in: entries)
        return Button {
            selectedID = entry.id
            sourceField = entry.value(of: targetField).isEmpty ? nil : targetField
            revealsPassword = false
        } label: {
            HStack(spacing: 10) {
                LetterTile(title: entry.title, size: 28, cornerRadius: 8, fontSize: 13, colorHex: entry.backgroundColorHex, iconPNGData: entry.iconPNGData, iconID: entry.iconID)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    Text(linksBack ? L("Links back to this entry") : subtitle(of: entry))
                        .font(.system(size: 11))
                        .foregroundStyle(linksBack ? KM.warning : KM.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: 9)
        .disabled(linksBack)
        .opacity(linksBack ? 0.5 : 1)
    }

    // MARK: - Picking a field

    private func chosen(_ source: VaultEntry) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                LetterTile(title: source.title, size: 28, cornerRadius: 8, fontSize: 13, colorHex: source.backgroundColorHex, iconPNGData: source.iconPNGData, iconID: source.iconID)
                VStack(alignment: .leading, spacing: 1) {
                    Text(source.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text(subtitle(of: source))
                        .font(.system(size: 11))
                        .foregroundStyle(KM.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(L("Change")) {
                    selectedID = nil
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(KM.accent)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(KM.insetFill))

            VStack(spacing: 0) {
                ForEach(Array(VaultFieldReference.Field.allCases.enumerated()), id: \.element) { index, field in
                    fieldRow(field, of: source, isFirst: index == 0)
                }
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(KM.insetFill))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(KM.hairline, lineWidth: 0.5))
        }
        .padding(.top, 14)
    }

    private func fieldRow(_ field: VaultFieldReference.Field, of source: VaultEntry, isFirst: Bool) -> some View {
        let value = source.value(of: field)
        let isEmpty = value.isEmpty
        let isSelected = sourceField == field && !isEmpty
        let isPassword = field == .password && !isEmpty
        return HStack(spacing: 10) {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 15))
                .foregroundStyle(isSelected ? KM.accent : KM.textSecondary)
            Text(field.title)
                .font(.system(size: 13))
                .frame(width: 78, alignment: .leading)
            Text(isEmpty ? L("Empty") : (isPassword && !revealsPassword ? String(repeating: "•", count: 12) : value.components(separatedBy: .newlines).first ?? ""))
                .font(.system(size: 12, design: isPassword ? .monospaced : .default))
                .foregroundStyle(KM.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if isPassword {
                Button {
                    revealsPassword.toggle()
                } label: {
                    Image(systemName: revealsPassword ? "eye.slash" : "eye")
                        .font(.system(size: 12))
                }
                .buttonStyle(KMIconButtonStyle(size: 26, cornerRadius: 7))
                .iconHelp(revealsPassword ? L("Hide") : L("Show"))
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(minHeight: 40)
        .contentShape(Rectangle())
        .onTapGesture {
            if !isEmpty {
                sourceField = field
            }
        }
        .opacity(isEmpty ? 0.45 : 1)
        .overlay(alignment: .top) {
            if !isFirst {
                Rectangle().fill(KM.hairline).frame(height: 0.5)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Helpers

    private var summary: String {
        guard canInsert, let source, let sourceField else {
            return ""
        }
        if sourceField == targetField {
            return L("\(targetField.title) will always match “\(source.title)”")
        }
        return L("\(targetField.title) will always match \(sourceField.title) of “\(source.title)”")
    }

    private func subtitle(of entry: VaultEntry) -> String {
        // Entries at the top level don't show the root group's name.
        let group = entry.groupPath.contains(".") ? GroupPathFormatter.title(of: entry.groupPath) : ""
        return [entry.username ?? "", group].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func insert() {
        guard canInsert, let source, let sourceField else {
            return
        }
        onInsert(VaultFieldReference(field: sourceField, entryID: source.id))
        dismiss()
    }
}
