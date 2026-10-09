import AppKit
import Data
import Domain
import LocalAuthentication
import SwiftUI
import UniformTypeIdentifiers

/// Vault → Export…: format and scope, then the user confirms with the master password or Touch ID.
struct ExportSheet: View {
    let vault: LoadedVault
    let viewModel: AppViewModel
    /// The group selected in the sidebar, offered as "Current group".
    let currentGroupPath: String?

    @Environment(\.dismiss) private var dismiss
    @State private var format: VaultExportFormat = .keePassXML
    @State private var exportsCurrentGroup = false
    @State private var includesTrash = false
    @State private var includesHistory = true
    @State private var includesAttachments = true
    @State private var isConfirming = false

    private var isCSV: Bool { format == .csv }

    private var options: VaultExportOptions {
        VaultExportOptions(
            format: format,
            groupPath: exportsCurrentGroup ? currentGroupPath : nil,
            includesTrash: includesTrash,
            includesHistory: !isCSV && includesHistory,
            includesAttachments: !isCSV && includesAttachments
        )
    }

    /// Entries the export will hold, for the confirmation.
    private var entryCount: Int {
        vault.entries.filter { entry in
            guard includesTrash || !entry.isTrashed else {
                return false
            }
            guard let path = options.groupPath else {
                return true
            }
            return entry.groupPath == path || entry.groupPath.hasPrefix(path + ".")
        }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 14) {
                card {
                    cardRow(L("Format"), isFirst: true) {
                        KMSegmentedControl(
                            options: [(VaultExportFormat.keePassXML, L("KeePass XML")), (VaultExportFormat.csv, L("CSV"))],
                            selection: $format,
                            fontSize: 12,
                            horizontalPadding: 12
                        )
                        .fixedSize()
                    }
                    cardRow(L("Export")) {
                        KMSegmentedControl(
                            options: [(false, L("Entire database")), (true, currentGroupPath.map { L("Current group: \(GroupPathFormatter.title(of: $0))") } ?? L("Current group"))],
                            selection: $exportsCurrentGroup,
                            fontSize: 12,
                            horizontalPadding: 12,
                            disabled: currentGroupPath == nil ? [true] : []
                        )
                        .fixedSize()
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    card {
                        cardRow(L("Include Trash"), isFirst: true) {
                            toggle($includesTrash)
                        }
                        cardRow(L("Include history")) {
                            toggle(Binding(get: { !isCSV && includesHistory }, set: { includesHistory = $0 }))
                                .disabled(isCSV)
                        }
                        .opacity(isCSV ? 0.45 : 1)
                        cardRow(L("Include attachments")) {
                            toggle(Binding(get: { !isCSV && includesAttachments }, set: { includesAttachments = $0 }))
                                .disabled(isCSV)
                        }
                        .opacity(isCSV ? 0.45 : 1)
                    }
                    if isCSV {
                        Text(L("CSV can’t store history or attachments"))
                            .font(.system(size: 11))
                            .foregroundStyle(KM.textSecondary)
                            .padding(.leading, 4)
                    }
                }
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(KM.warning)
                    Text(L("The exported file isn’t encrypted. Anyone who gets it can read every password. Delete it when you’re done."))
                        .font(.system(size: 12))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(KM.warning.opacity(0.12)))
            }
            .padding(.top, 18)

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(L("Cancel")) {
                    dismiss()
                }
                .buttonStyle(KMButtonStyle(kind: .secondary, height: 30))
                .keyboardShortcut(.cancelAction)
                Button(L("Export…")) {
                    isConfirming = true
                }
                .buttonStyle(KMButtonStyle(kind: .primary, height: 30, horizontalPadding: 18, fontWeight: .semibold))
                .keyboardShortcut(.defaultAction)
                .disabled(entryCount == 0)
            }
            .padding(.top, 20)
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 18)
        .frame(width: 560)
        .background(KM.sheetBackground)
        .sheet(isPresented: $isConfirming) {
            ExportConfirmView(entryCount: entryCount, viewModel: viewModel) {
                isConfirming = false
                save()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(KM.accent)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(KM.accent.opacity(0.14)))
            VStack(alignment: .leading, spacing: 1) {
                Text(L("Export Database"))
                    .font(.system(size: 15, weight: .bold))
                Text(vault.summary.fileName)
                    .font(.system(size: 11))
                    .foregroundStyle(KM.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func card<Content: View>(@ViewBuilder _ rows: () -> Content) -> some View {
        VStack(spacing: 0) {
            rows()
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(KM.insetFill))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(KM.hairline, lineWidth: 0.5))
    }

    private func cardRow<Trailing: View>(_ title: String, isFirst: Bool = false, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 13))
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

    private func toggle(_ isOn: Binding<Bool>) -> some View {
        Toggle("", isOn: isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(KM.success)
    }

    /// Asks where to save, writes the file readable only by the user and reports it in a toast.
    private func save() {
        let options = options
        let panel = NSSavePanel()
        let baseName = (vault.summary.fileName as NSString).deletingPathExtension
        panel.nameFieldStringValue = "\(baseName).\(options.format.fileExtension)"
        panel.allowedContentTypes = [options.format == .csv ? .commaSeparatedText : .xml]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        dismiss()
        Task {
            do {
                let export = try await viewModel.exportDatabase(options)
                try export.data.write(to: url, options: [.atomic])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                CopyFeedbackCenter.shared.show(
                    L("Exported \(export.entryCount) entries to \(url.lastPathComponent)"),
                    style: .success,
                    duration: 6,
                    actionTitle: L("Show in Finder")
                ) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                CopyFeedbackCenter.shared.show(
                    L("Couldn’t export: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"),
                    style: .success,
                    duration: 4
                )
            }
        }
    }
}

/// "Confirm it's you" before writing an unencrypted file: master password or Touch ID.
struct ExportConfirmView: View {
    let entryCount: Int
    let viewModel: AppViewModel
    let onConfirmed: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var isChecking = false
    @State private var isWaitingForTouchID = false
    @State private var shake = 0
    @FocusState private var isPasswordFocused: Bool

    private var canUseTouchID: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                AppIconImage(size: 56)
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(KM.accent)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(KM.raisedFieldBackground))
                    .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
                    .offset(x: 6, y: 6)
            }
            .accessibilityHidden(true)

            Text(L("Confirm it’s you"))
                .font(.system(size: 13, weight: .bold))
                .padding(.top, 14)
            Text(L("to export \(entryCount) entries"))
                .font(.system(size: 11))
                .foregroundStyle(KM.textSecondary)
                .padding(.top, 4)

            SecureField(L("Master password"), text: $password)
                .textFieldStyle(.plain)
                .focused($isPasswordFocused)
                .onSubmit(confirmWithPassword)
                .kmField(focused: isPasswordFocused, height: 28)
                .modifier(ShakeEffect(shakes: CGFloat(shake)))
                .padding(.top, 14)
                .disabled(isChecking || isWaitingForTouchID)
                .onChange(of: password) { _, _ in
                    errorMessage = nil
                }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(KM.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            }

            VStack(spacing: 6) {
                Button(L("Export"), action: confirmWithPassword)
                    .buttonStyle(KMButtonStyle(kind: .primary, height: 28, fullWidth: true, fontWeight: .semibold))
                    .keyboardShortcut(.defaultAction)
                    .disabled(isChecking || isWaitingForTouchID)
                if canUseTouchID {
                    Button(action: confirmWithTouchID) {
                        HStack(spacing: 6) {
                            Image(systemName: "touchid")
                                .foregroundStyle(isWaitingForTouchID ? KM.touchID : KM.textPrimary)
                            Text(isWaitingForTouchID ? L("Touch the sensor…") : L("Confirm with Touch ID"))
                        }
                    }
                    .buttonStyle(KMButtonStyle(kind: .secondary, height: 28, fullWidth: true))
                    .disabled(isChecking || isWaitingForTouchID)
                }
                Button(L("Cancel")) {
                    dismiss()
                }
                .buttonStyle(KMButtonStyle(kind: .secondary, height: 28, fullWidth: true))
                .keyboardShortcut(.cancelAction)
            }
            .padding(.top, 14)
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .frame(width: 270)
        .multilineTextAlignment(.center)
        .background(KM.dialogBackground)
        .onAppear {
            isPasswordFocused = true
        }
    }

    private func confirmWithPassword() {
        guard !password.isEmpty else {
            fail(L("Enter the master password."))
            return
        }
        isChecking = true
        let entered = password
        Task {
            let valid = await viewModel.verifyMasterKey(password: entered)
            isChecking = false
            if valid {
                password = ""
                onConfirmed()
            } else {
                fail(L("Wrong password. Try again."))
            }
        }
    }

    private func confirmWithTouchID() {
        isWaitingForTouchID = true
        Task {
            let context = LAContext()
            let confirmed = (try? await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: L("export \(entryCount) entries")
            )) ?? false
            isWaitingForTouchID = false
            if confirmed {
                onConfirmed()
            }
        }
    }

    private func fail(_ message: String) {
        errorMessage = message
        withAnimation(.easeOut(duration: 0.38)) {
            shake += 1
        }
    }
}

/// Horizontal shake for a rejected password.
private struct ShakeEffect: GeometryEffect {
    var shakes: CGFloat

    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 7 * sin(shakes * .pi * 4), y: 0))
    }
}
