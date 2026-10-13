import AppKit
import Domain
import SwiftUI

/// What Auto-Type tells the user in its floating notice.
enum AutoTypeNotice: Equatable {
    case permission
    case secureInput(appName: String)
    case failed(AutoTypeSequenceError, entryTitle: String, entryID: UUID)
    case typing(entry: VaultEntry, appName: String)

    var isTyping: Bool {
        if case .typing = self {
            return true
        }
        return false
    }
}

/// A notice under the menu bar icon, like Quick Access. It doesn't take the keyboard, so the app
/// Auto-Type types into keeps focus.
@MainActor
final class AutoTypeNoticeController {
    static let shared = AutoTypeNoticeController()
    static let width: CGFloat = 344

    private var panel: QuickAccessPanel?
    private var hideTask: Task<Void, Never>?
    private(set) var current: AutoTypeNotice?

    private init() {}

    func show(_ notice: AutoTypeNotice) {
        hideTask?.cancel()
        current = notice
        let panel = panel ?? makePanel()
        self.panel = panel
        let view = AutoTypeNoticeView(notice: notice) { [weak self] action in
            self?.perform(action)
        }
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: CGSize(width: Self.width, height: 120))
        panel.contentView = hosting
        let size = CGSize(width: Self.width, height: max(hosting.fittingSize.height, 60))
        panel.setFrame(frame(for: size), display: false)
        panel.orderFrontRegardless()

        // Notices go away by themselves; typing ends with `hideTyping()`.
        guard !notice.isTyping else {
            return
        }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else {
                return
            }
            self?.hide()
        }
    }

    func hideTyping() {
        if current?.isTyping == true {
            hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        current = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
    }

    private func perform(_ action: AutoTypeNoticeView.Action) {
        let notice = current
        hide()
        switch action {
        case .dismiss:
            break
        case .openSystemSettings:
            AccessibilityPermission.openSystemSettings()
        case .editEntry:
            guard case .failed(_, _, let entryID) = notice else {
                return
            }
            NotificationCenter.default.post(name: AppCommand.showMainWindow, object: nil)
            // The browser picks up reveal requests only once it is on screen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                AutoTypeController.shared.revealForEditing(entryID)
            }
        }
    }

    private func makePanel() -> QuickAccessPanel {
        let panel = QuickAccessPanel(
            contentRect: NSRect(origin: .zero, size: CGSize(width: Self.width, height: 120)),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovable = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.setAccessibilityLabel(L("Auto-Type"))
        panel.setAccessibilityIdentifier("autoType.notice")
        return panel
    }

    /// Where Quick Access opens: under the menu bar icon, or at the top right of the screen with the pointer.
    private func frame(for size: CGSize) -> NSRect {
        let statusWindow = NSApp.windows.first { $0.className.contains("NSStatusBarWindow") && $0.isVisible }
        let mouseScreen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
        let screen = statusWindow?.screen ?? mouseScreen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin: NSPoint
        if let anchor = statusWindow?.frame {
            origin = NSPoint(x: anchor.midX - size.width / 2, y: visible.maxY - size.height - 6)
        } else {
            origin = NSPoint(x: visible.maxX - size.width - 12, y: visible.maxY - size.height - 6)
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        return NSRect(origin: origin, size: size)
    }
}

struct AutoTypeNoticeView: View {
    enum Action {
        case dismiss
        case openSystemSettings
        case editEntry
    }

    let notice: AutoTypeNotice
    let perform: (Action) -> Void

    var body: some View {
        content
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 12)
            .frame(width: AutoTypeNoticeController.width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(KM.menuBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(KM.chromeBorder, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .tint(KM.accent)
    }

    @ViewBuilder
    private var content: some View {
        switch notice {
        case .typing(let entry, let appName):
            HStack(spacing: 10) {
                EntryTile(entry: entry, supportsTypes: false, size: 32, cornerRadius: 8, fontSize: 14)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(L("Typing…"))
                            .font(.system(size: 13, weight: .semibold))
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Text(L("\(entry.title) into \(appName) — keep your hands off the keyboard"))
                        .font(.system(size: 12))
                        .foregroundStyle(KM.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("autoType.typing")
        case .permission:
            VStack(alignment: .leading, spacing: 12) {
                header(
                    title: L("Accessibility access needed"),
                    body: Text(L("KeeMac needs Accessibility to read the window title and type into other apps."))
                )
                HStack(spacing: 6) {
                    Button(L("Not Now")) { perform(.dismiss) }
                        .buttonStyle(KMButtonStyle(kind: .secondary, height: 32, fullWidth: true))
                        .accessibilityIdentifier("autoType.notNow")
                    Button(L("Open System Settings…")) { perform(.openSystemSettings) }
                        .buttonStyle(KMButtonStyle(kind: .primary, height: 32, fullWidth: true, fontWeight: .semibold))
                        .accessibilityIdentifier("autoType.openSystemSettings")
                        .layoutPriority(1)
                }
            }
        case .secureInput(let appName):
            VStack(alignment: .leading, spacing: 12) {
                header(
                    title: L("Secure input is on in \(appName)"),
                    body: Text(L("KeeMac can’t type there. Turn off Secure Keyboard Entry or close the password prompt."))
                )
                HStack {
                    Spacer()
                    Button(L("OK")) { perform(.dismiss) }
                        .buttonStyle(KMButtonStyle(kind: .primary, height: 32, fontWeight: .semibold))
                        .accessibilityIdentifier("autoType.ok")
                }
            }
        case .failed(let error, let entryTitle, _):
            VStack(alignment: .leading, spacing: 12) {
                header(title: L("Auto-Type failed"), body: failureText(error, entryTitle: entryTitle), closable: true)
                HStack {
                    Spacer()
                    Button(L("Edit Entry")) { perform(.editEntry) }
                        .buttonStyle(KMButtonStyle(kind: .primary, height: 32, fontWeight: .semibold))
                        .accessibilityIdentifier("autoType.editEntry")
                }
            }
        }
    }

    private func header(title: String, body: Text, closable: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            AppIconImage(size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                body
                    .font(.system(size: 12))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.trailing, closable ? 18 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("autoType.message")
        }
        .overlay(alignment: .topTrailing) {
            if closable {
                Button { perform(.dismiss) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(KMIconButtonStyle(size: 22, cornerRadius: 6))
                .iconHelp(L("Close"))
                .offset(x: 4, y: -4)
            }
        }
    }

    /// "Unknown command {PASWORD} in GitHub" with the command in monospace.
    private func failureText(_ error: AutoTypeSequenceError, entryTitle: String) -> Text {
        guard case .unknownCommand(let command) = error else {
            return Text(L("\(error.message) in \(entryTitle)"))
        }
        let code = Text(command)
            .font(.system(size: 11, design: .monospaced))
        return Text(L("Unknown command")) + Text(" ") + code + Text(L(" in \(entryTitle)"))
    }
}
