import AppKit
import Domain
import SwiftUI

enum SSHAgentPanelResult: Equatable {
    case allowOnce
    case allowUntilLock
    case deny
}

/// A floating panel near the top right, like Quick Access: the main window may be hidden and KeeMac inactive.
@MainActor
final class SSHAgentPanelController: NSObject, NSWindowDelegate {
    private var panel: QuickAccessPanel?
    private var finish: ((SSHAgentPanelResult) -> Void)?

    static let size = CGSize(width: 372, height: 300)

    func show(_ prompt: SSHAgentPrompt, viewModel: AppViewModel, onFinish: @escaping (SSHAgentPanelResult) -> Void) {
        finish = onFinish
        let panel = panel ?? makePanel()
        self.panel = panel
        let view = SSHAgentPromptView(prompt: prompt, viewModel: viewModel) { [weak self] result in
            self?.complete(result)
        }
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: Self.size)
        panel.contentView = hosting
        panel.keyHandler = { [weak self] event in
            guard event.keyCode == 53 else { return false }
            self?.complete(.deny)
            return true
        }
        let fitting = hosting.fittingSize
        panel.setFrame(frame(for: CGSize(width: Self.size.width, height: max(fitting.height, 120))), display: false)
        if prompt.kind == .unlock {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    private func complete(_ result: SSHAgentPanelResult) {
        guard let finish else { return }
        self.finish = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        finish(result)
    }

    private func makePanel() -> QuickAccessPanel {
        let panel = QuickAccessPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.delegate = self
        panel.setAccessibilityLabel(L("SSH key requested"))
        return panel
    }

    private func frame(for size: CGSize) -> NSRect {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(x: visible.maxX - size.width - 14, y: visible.maxY - size.height - 10, width: size.width, height: size.height)
    }
}

struct SSHAgentPromptView: View {
    let prompt: SSHAgentPrompt
    @Bindable var viewModel: AppViewModel
    let onFinish: (SSHAgentPanelResult) -> Void

    private static let timeout = 30
    @State private var secondsLeft = SSHAgentPromptView.timeout
    @State private var isHovered = false
    @State private var password = ""
    @State private var revealsPassword = false
    @State private var isUnlocking = false
    @State private var isWrong = false
    @FocusState private var isPasswordFocused: Bool
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var canUseTouchID: Bool {
        viewModel.showBiometricUnlockScreen && viewModel.touchIDEnabledForSelectedVault
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                AppIconImage(size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("SSH key requested"))
                        .font(.system(size: 13, weight: .semibold))
                    Text(prompt.kind == .unlock
                         ? L("\(viewModel.selectedVaultURL?.deletingPathExtension().lastPathComponent ?? "") is locked")
                         : L("KeeMac SSH agent"))
                        .font(.system(size: 11))
                        .foregroundStyle(KM.textSecondary)
                }
                Spacer(minLength: 0)
            }

            requestCard

            if prompt.kind == .unlock {
                unlockControls
            } else {
                confirmControls
            }
        }
        .padding(14)
        .frame(width: SSHAgentPanelController.size.width)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(KM.menuBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(KM.chromeBorder, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onHover { isHovered = $0 }
        .onReceive(timer) { _ in
            guard prompt.kind == .confirm, !isHovered else { return }
            secondsLeft -= 1
            if secondsLeft <= 0 {
                onFinish(.deny)
            }
        }
        .onAppear {
            if prompt.kind == .unlock {
                isPasswordFocused = true
                if canUseTouchID {
                    unlockWithTouchID()
                }
            }
        }
    }

    private var requestCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardRow {
                Group {
                    if let icon = prompt.appIcon {
                        Image(nsImage: icon).resizable()
                    } else {
                        Image(systemName: "terminal")
                            .font(.system(size: 13))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(white: 0.2)))
                    }
                }
                .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 0) {
                    Text(prompt.processName)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                    if let app = prompt.appName {
                        Text(L("from \(app)"))
                            .font(.system(size: 11))
                            .foregroundStyle(KM.textSecondary)
                    }
                }
            }
            if prompt.kind == .confirm || prompt.host != nil {
                cardRow {
                    Image(systemName: "server.rack")
                        .font(.system(size: 13))
                        .foregroundStyle(KM.textSecondary)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(L("Server"))
                            .font(.system(size: 10))
                            .foregroundStyle(KM.textSecondary)
                        Text(prompt.host ?? L("Unknown host"))
                            .font(.system(size: 13, design: prompt.host == nil ? .default : .monospaced))
                            .foregroundStyle(prompt.host == nil ? KM.textSecondary : KM.textPrimary)
                    }
                }
            }
            if let title = prompt.keyTitle {
                cardRow {
                    LetterTile(title: title, size: 24, cornerRadius: 6, fontSize: 11)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        if let fingerprint = prompt.keyFingerprint {
                            Text(fingerprint)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(KM.textSecondary)
                        }
                    }
                }
            } else if prompt.kind == .unlock {
                cardRow {
                    Image(systemName: "key.horizontal")
                        .font(.system(size: 13))
                        .foregroundStyle(KM.textSecondary)
                        .frame(width: 24)
                    Text(L("ssh asks for a key for \(prompt.host ?? L("an unknown host"))"))
                        .font(.system(size: 12))
                        .foregroundStyle(KM.textSecondary)
                }
            }
            if prompt.isForwarded {
                cardRow {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(KM.warning)
                        .frame(width: 24)
                    Text(L("Forwarded from another server (agent forwarding)"))
                        .font(.system(size: 12))
                        .foregroundStyle(KM.warning)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(KM.insetFill))
    }

    private func cardRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var confirmControls: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Button(L("Deny")) { onFinish(.deny) }
                    .buttonStyle(KMButtonStyle(kind: .secondary, height: 30, fontWeight: .regular))
                Button(L("Allow Once")) { onFinish(.allowOnce) }
                    .buttonStyle(KMButtonStyle(kind: .secondary, height: 30, fontWeight: .regular))
                Button(L("Allow Until Lock")) { onFinish(.allowUntilLock) }
                    .buttonStyle(KMButtonStyle(kind: .primary, height: 30, horizontalPadding: 14, fontWeight: .semibold))
                    .keyboardShortcut(.defaultAction)
            }
            .frame(maxWidth: .infinity)
            Text(L("Denied automatically in \(secondsLeft) s"))
                .font(.system(size: 10))
                .foregroundStyle(KM.textTertiary)
                .opacity(isHovered ? 0.4 : 1)
        }
    }

    private var unlockControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if canUseTouchID {
                Button(action: unlockWithTouchID) {
                    Label(L("Unlock with Touch ID"), systemImage: "touchid")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(KMButtonStyle(kind: .secondary, height: 30, fontWeight: .regular))
                .disabled(isUnlocking)
            }
            HStack(spacing: 0) {
                Group {
                    if revealsPassword {
                        TextField(L("Master password"), text: $password)
                    } else {
                        SecureField(L("Master password"), text: $password)
                    }
                }
                .textFieldStyle(.plain)
                .focused($isPasswordFocused)
                .onSubmit(unlockWithPassword)
                .onChange(of: password) {
                    isWrong = false
                }
                Button {
                    revealsPassword.toggle()
                } label: {
                    Image(systemName: revealsPassword ? "eye.slash" : "eye").font(.system(size: 12))
                }
                .buttonStyle(KMIconButtonStyle(size: 22, cornerRadius: 5))
                .iconHelp(revealsPassword ? L("Hide password") : L("Show password"))
            }
            .kmField(focused: isPasswordFocused, invalid: isWrong, background: KM.fieldBackground)
            .disabled(isUnlocking)
            if isWrong {
                Label(L("Wrong password. Try again."), systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(KM.danger)
            }
            HStack(spacing: 8) {
                Spacer()
                Button(L("Cancel")) { onFinish(.deny) }
                    .buttonStyle(KMButtonStyle(kind: .secondary, height: 30, fontWeight: .regular))
                    .disabled(isUnlocking)
                Button(action: unlockWithPassword) {
                    HStack(spacing: 6) {
                        if isUnlocking {
                            ProgressView().controlSize(.mini).tint(.white)
                        }
                        Text(isUnlocking ? L("Unlocking…") : L("Unlock and Allow"))
                    }
                }
                .buttonStyle(KMButtonStyle(kind: .primary, height: 30, horizontalPadding: 14, fontWeight: .semibold))
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty || isUnlocking)
            }
        }
    }

    private func unlockWithPassword() {
        guard !password.isEmpty, !isUnlocking else { return }
        isUnlocking = true
        let entered = password
        Task {
            await viewModel.unlock(masterPassword: entered)
            finishUnlock()
        }
    }

    private func unlockWithTouchID() {
        guard !isUnlocking else { return }
        isUnlocking = true
        Task {
            await viewModel.unlockWithBiometrics()
            finishUnlock()
        }
    }

    private func finishUnlock() {
        isUnlocking = false
        if viewModel.loadState.isUnlocked {
            password = ""
            onFinish(.allowUntilLock)
        } else if case .failed = viewModel.loadState {
            isWrong = true
            isPasswordFocused = true
            DispatchQueue.main.async {
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            }
        } else {
            isPasswordFocused = true
        }
    }
}
