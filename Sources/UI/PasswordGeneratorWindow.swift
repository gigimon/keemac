import AppKit
import SwiftUI

/// Standalone generator ("Generate Password…", ⌥⌘G). It never touches a database,
/// so it works while every database is locked. With `onFill` it also serves KeePassXC-Browser's generator button.
public struct PasswordGeneratorWindowView: View {
    private let onFill: ((String) -> Void)?
    @State private var settings = PasswordGeneratorSettings.shared
    @State private var value: String
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?

    public init(onFill: ((String) -> Void)? = nil) {
        self.onFill = onFill
        _value = State(initialValue: PasswordGeneratorSettings.shared.generate())
    }

    private var options: PasswordGeneratorOptions { settings.options }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            KMSegmentedControl(
                options: PasswordGeneratorOptions.Mode.allCases.map { ($0, $0.title) },
                selection: optionBinding(\.mode),
                fontSize: 12,
                horizontalPadding: 12,
                identifierPrefix: "generator.mode"
            )
            .frame(maxWidth: .infinity)

            result

            HStack(spacing: 8) {
                GeneratorStrengthLabel(strength: .forEntropy(PasswordGenerator.entropyBits(options)))
                Spacer(minLength: 0)
                Button(action: regenerate) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 13))
                }
                .buttonStyle(KMIconButtonStyle(size: 28, cornerRadius: 14, tint: KM.textPrimary, filled: true))
                .iconHelp(L("Regenerate (⌘R)"))
                .accessibilityIdentifier("generator.regenerate")
                .keyboardShortcut("r", modifiers: [.command])
                Button(action: copy) {
                    Label(L("Copy"), systemImage: "doc.on.doc")
                }
                .buttonStyle(KMButtonStyle(kind: onFill == nil ? .primary : .secondary, height: 28, horizontalPadding: 14, fontWeight: .semibold, fontSize: 12))
                .help(L("Copy (⌘C)"))
                .accessibilityIdentifier("generator.copy")
                .keyboardShortcut("c", modifiers: [.command])
                if let onFill {
                    Button(L("Fill Password")) {
                        onFill(value)
                    }
                    .buttonStyle(KMButtonStyle(kind: .primary, height: 28, horizontalPadding: 14, fontWeight: .semibold, fontSize: 12))
                    .keyboardShortcut(.defaultAction)
                    .disabled(value.isEmpty)
                }
            }

            Rectangle()
                .fill(KM.hairline)
                .frame(height: 0.5)

            GeneratorOptionsView(options: optionBinding(\.self), layout: .window)

            Text(onFill == nil ? L("Generated passwords aren’t stored.") : L("Save the login in the browser to keep this password."))
                .font(.system(size: 11))
                .foregroundStyle(KM.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 2)
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
        .background(KM.unlockBackground.ignoresSafeArea())
        .overlay(alignment: .bottom) {
            if let toast {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(KM.success)
                    Text(toast)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(KM.toastText)
                        .lineLimit(1)
                }
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(Capsule(style: .continuous).fill(KM.toastBackground))
                .shadow(color: .black.opacity(0.25), radius: 12, y: 8)
                .padding(.bottom, 14)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toast)
        .tint(KM.accent)
        .onReceive(NotificationCenter.default.publisher(for: PasswordGeneratorWindowController.regenerateNotification)) { _ in
            regenerate()
        }
    }

    /// Large monospaced result; digits in accent, symbols in orange like the entry card.
    private var result: some View {
        let size: CGFloat = value.count <= 22 ? 22 : (value.count <= 36 ? 18 : 15)
        return Text(colorized(value))
            .accessibilityIdentifier("generator.result")
            .font(.system(size: size, design: .monospaced))
            .kerning(0.3)
            .lineSpacing(4)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(lightHex: 0xFFFFFF, darkHex: 0x1C1C1E))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(KM.softBorder, lineWidth: 0.5)
            )
    }

    private func colorized(_ text: String) -> AttributedString {
        var result = AttributedString()
        for character in text {
            var piece = AttributedString(String(character))
            if character.isNumber {
                piece.foregroundColor = KM.accent
            } else if !character.isLetter {
                piece.foregroundColor = KM.symbolChar
            }
            result.append(piece)
        }
        return result
    }

    private func optionBinding<Value>(_ keyPath: WritableKeyPath<PasswordGeneratorOptions, Value>) -> Binding<Value> {
        Binding(
            get: { settings.options[keyPath: keyPath] },
            set: { newValue in
                settings.options[keyPath: keyPath] = newValue
                regenerate()
            }
        )
    }

    private func regenerate() {
        value = settings.generate()
    }

    private func copy() {
        guard !value.isEmpty else {
            return
        }
        let message = SensitiveClipboard.shared.copySensitiveText(
            value,
            label: options.mode == .password ? L("Password") : L("Passphrase"),
            showsToast: false
        )
        toastTask?.cancel()
        toast = message
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.6))
            guard !Task.isCancelled else {
                return
            }
            toast = nil
        }
    }
}

@MainActor
public final class PasswordGeneratorWindowController: NSObject, NSWindowDelegate {
    public static let shared = PasswordGeneratorWindowController()

    /// Each time the window is opened again it shows a fresh value.
    static let regenerateNotification = Notification.Name("KeeMac.PasswordGenerator.Regenerate")

    private var window: NSWindow?

    public func show() {
        if let window {
            NotificationCenter.default.post(name: Self.regenerateNotification, object: nil)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: PasswordGeneratorWindowView())
        let window = NSWindow(contentViewController: hosting)
        window.title = L("Password Generator")
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    public func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
