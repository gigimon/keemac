import AppKit
import Domain
import HardwareKey
import SwiftUI

/// Where KeeMac's hardware keys come from: USB, or in UI testing a software key (none unless a test sets one).
public enum HardwareKeys {
    public static let device: any HardwareKeyChallenging = {
        if UITesting.isActive {
            return UITesting.hardwareKey ?? NoHardwareKeys()
        }
        return YubiKeyHIDChallenger.shared
    }()

    /// What the loader asks: the device behind the touch panel.
    public static let prompting: any HardwareKeyChallenging = PromptingHardwareKeyChallenger(device: device)
}

private struct NoHardwareKeys: HardwareKeyChallenging {
    func connectedKeys() throws -> [VaultHardwareKey] { [] }

    func challengeResponse(_ challenge: Data, key: VaultHardwareKey, isCancelled: @escaping @Sendable () -> Bool) throws -> Data {
        throw VaultError.hardwareKeyNotFound(serial: key.serial)
    }
}

/// What the "Touch your YubiKey" panel shows.
enum HardwareKeyPromptState: Equatable {
    case waiting
    case responded
    case timedOut
    case notFound
    case slotNotConfigured

    /// The panel waits for the user to pick Try Again, Cancel or OK.
    var isError: Bool {
        switch self {
        case .waiting, .responded:
            return false
        case .timedOut, .notFound, .slotNotConfigured:
            return true
        }
    }
}

enum HardwareKeyPromptDecision: Sendable {
    case retry
    case cancel
    /// "OK" on an error that Try Again can't fix.
    case giveUp
}

/// Asks the real device and keeps the user informed: shows the touch panel while a challenge runs,
/// offers Try Again on errors, and lets Cancel abort a challenge that waits for a touch.
final class PromptingHardwareKeyChallenger: HardwareKeyChallenging, @unchecked Sendable {
    private let device: any HardwareKeyChallenging
    /// A slot without touch answers in milliseconds; the panel only shows when it takes longer.
    private let quietPeriod: TimeInterval

    init(device: any HardwareKeyChallenging, quietPeriod: TimeInterval = 0.4) {
        self.device = device
        self.quietPeriod = quietPeriod
    }

    func connectedKeys() throws -> [VaultHardwareKey] {
        try device.connectedKeys()
    }

    func challengeResponse(_ challenge: Data, key: VaultHardwareKey, isCancelled: @escaping @Sendable () -> Bool) throws -> Data {
        while true {
            let attempt = HardwareKeyAttempt()
            let delay = key.requiresTouch ? 0 : quietPeriod
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated {
                    if !attempt.isFinished {
                        HardwareKeyPromptController.shared.show(key: key, state: .waiting, attempt: attempt)
                    }
                }
            }
            do {
                let response = try device.challengeResponse(challenge, key: key) {
                    attempt.isCancelled || isCancelled()
                }
                attempt.finish()
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        HardwareKeyPromptController.shared.finish(attempt: attempt)
                    }
                }
                return response
            } catch let error as VaultError {
                attempt.finish()
                let state: HardwareKeyPromptState
                switch error {
                case .hardwareKeyTimedOut:
                    state = .timedOut
                case .hardwareKeyNotFound:
                    state = .notFound
                case .hardwareKeySlotNotConfigured:
                    state = .slotNotConfigured
                default:
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            HardwareKeyPromptController.shared.hide(attempt: attempt)
                        }
                    }
                    throw error
                }
                switch askUser(key: key, state: state, attempt: attempt) {
                case .retry:
                    continue
                case .cancel:
                    throw VaultError.hardwareKeyCancelled
                case .giveUp:
                    throw error
                }
            }
        }
    }

    /// Blocks this (non-main) thread until the user answers the error panel.
    private func askUser(key: VaultHardwareKey, state: HardwareKeyPromptState, attempt: HardwareKeyAttempt) -> HardwareKeyPromptDecision {
        let answered = DispatchSemaphore(value: 0)
        let decision = HardwareKeyDecisionBox()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                HardwareKeyPromptController.shared.show(key: key, state: state, attempt: attempt) { choice in
                    decision.value = choice
                    answered.signal()
                }
            }
        }
        answered.wait()
        return decision.value
    }
}

/// One challenge as the panel sees it; Cancel sets the flag the device polls.
final class HardwareKeyAttempt: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var finished = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    var isFinished: Bool { lock.withLock { finished } }

    func cancel() { lock.withLock { cancelled = true } }
    func finish() { lock.withLock { finished = true } }
}

private final class HardwareKeyDecisionBox: @unchecked Sendable {
    var value: HardwareKeyPromptDecision = .cancel
}

/// The floating "Touch your YubiKey" panel. It doesn't take focus, so it works over the unlock
/// screen, Quick Access and the SSH agent panel alike.
@MainActor
final class HardwareKeyPromptController {
    static let shared = HardwareKeyPromptController()
    static let width: CGFloat = 290

    private var panel: QuickAccessPanel?
    private var attempt: HardwareKeyAttempt?
    private var decide: ((HardwareKeyPromptDecision) -> Void)?
    private(set) var state: HardwareKeyPromptState?

    private init() {}

    func show(
        key: VaultHardwareKey,
        state: HardwareKeyPromptState,
        attempt: HardwareKeyAttempt,
        decide: ((HardwareKeyPromptDecision) -> Void)? = nil
    ) {
        self.attempt = attempt
        self.decide = decide
        self.state = state
        let panel = panel ?? makePanel()
        self.panel = panel
        let view = HardwareKeyPromptView(key: key, state: state) { [weak self] decision in
            self?.perform(decision)
        }
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: CGSize(width: Self.width, height: 200))
        panel.contentView = hosting
        let size = CGSize(width: Self.width, height: max(hosting.fittingSize.height, 120))
        panel.setFrame(frame(for: size), display: false)
        panel.orderFrontRegardless()
    }

    /// Shows the green check for a moment, then hides.
    func finish(attempt: HardwareKeyAttempt) {
        guard self.attempt === attempt, state != nil else {
            return
        }
        state = .responded
        if let hosting = panel?.contentView as? NSHostingView<HardwareKeyPromptView> {
            hosting.rootView = HardwareKeyPromptView(key: hosting.rootView.key, state: .responded) { [weak self] decision in
                self?.perform(decision)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            MainActor.assumeIsolated {
                self?.hide(attempt: attempt)
            }
        }
    }

    func hide(attempt: HardwareKeyAttempt) {
        guard self.attempt === attempt else {
            return
        }
        hide()
    }

    private func hide() {
        attempt = nil
        decide = nil
        state = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
    }

    private func perform(_ decision: HardwareKeyPromptDecision) {
        let decide = self.decide
        attempt?.cancel()
        hide()
        decide?(decision)
    }

    private func makePanel() -> QuickAccessPanel {
        let panel = QuickAccessPanel(
            contentRect: NSRect(origin: .zero, size: CGSize(width: Self.width, height: 200)),
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
        panel.setAccessibilityLabel(L("Hardware key"))
        panel.setAccessibilityIdentifier("hardwareKey.panel")
        return panel
    }

    /// Over the middle of KeeMac's main window when it is on screen, otherwise under the menu bar icon.
    private func frame(for size: CGSize) -> NSRect {
        let window = NSApp.windows.first { $0.isVisible && !($0 is NSPanel) && $0.styleMask.contains(.titled) && $0.frame.width > 400 }
        guard let window else {
            return QuickAccessController.menuBarPanelFrame(for: size)
        }
        let frame = window.frame
        return NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height)
    }
}

struct HardwareKeyPromptView: View {
    let key: VaultHardwareKey
    let state: HardwareKeyPromptState
    let perform: (HardwareKeyPromptDecision) -> Void

    @State private var pulse = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if state == .waiting {
                    Circle()
                        .stroke(tint.opacity(0.35), lineWidth: 2)
                        .frame(width: 64, height: 64)
                        .scaleEffect(pulse ? 1.25 : 0.95)
                        .opacity(pulse ? 0 : 1)
                        .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false), value: pulse)
                }
                Circle()
                    .fill(tint.opacity(0.14))
                    .frame(width: 56, height: 56)
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(tint)
            }
            .frame(height: 72)
            .padding(.bottom, 10)

            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("hardwareKey.title")
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(KM.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
                .accessibilityIdentifier("hardwareKey.subtitle")

            HStack(spacing: 8) {
                switch state {
                case .waiting, .responded:
                    Button(L("Cancel")) { perform(.cancel) }
                        .buttonStyle(KMButtonStyle(kind: .secondary, height: 30, fullWidth: true))
                        .accessibilityIdentifier("hardwareKey.cancel")
                case .timedOut, .notFound:
                    Button(L("Cancel")) { perform(.cancel) }
                        .buttonStyle(KMButtonStyle(kind: .secondary, height: 30, fullWidth: true))
                        .accessibilityIdentifier("hardwareKey.cancel")
                    Button(L("Try Again")) { perform(.retry) }
                        .buttonStyle(KMButtonStyle(kind: .primary, height: 30, fullWidth: true, fontWeight: .semibold))
                        .accessibilityIdentifier("hardwareKey.retry")
                case .slotNotConfigured:
                    Button(L("OK")) { perform(.giveUp) }
                        .buttonStyle(KMButtonStyle(kind: .primary, height: 30, fullWidth: true, fontWeight: .semibold))
                        .accessibilityIdentifier("hardwareKey.ok")
                }
            }
            .padding(.top, 16)
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 16)
        .frame(width: HardwareKeyPromptController.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(KM.menuBackground))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(KM.chromeBorder, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onAppear { pulse = true }
    }

    private var title: String {
        switch state {
        case .waiting, .responded:
            return L("Touch your YubiKey")
        case .timedOut:
            return L("Timed out waiting for touch")
        case .notFound:
            return L("Hardware key not found")
        case .slotNotConfigured:
            return L("This slot isn’t set up for challenge-response")
        }
    }

    private var subtitle: String {
        let name = L("YubiKey \(String(key.serial))")
        switch state {
        case .waiting:
            return L("\(key.shortLabel) is waiting for a touch")
        case .responded:
            return L("\(key.shortLabel) responded")
        case .timedOut:
            return L("Touch the gold contact on \(name) within 15 seconds.")
        case .notFound:
            return L("Plug in \(name) and try again.")
        case .slotNotConfigured:
            return L("Program Slot \(key.slot) with HMAC-SHA1 in YubiKey Manager, or choose another slot.")
        }
    }

    private var symbol: String {
        switch state {
        case .waiting:
            return "key.horizontal"
        case .responded:
            return "checkmark.circle.fill"
        case .timedOut:
            return "timer"
        case .notFound:
            return "cable.connector.slash"
        case .slotNotConfigured:
            return "exclamationmark.circle"
        }
    }

    private var tint: Color {
        switch state {
        case .waiting:
            return KM.accent
        case .responded:
            return KM.success
        case .timedOut, .notFound:
            return KM.warning
        case .slotNotConfigured:
            return KM.danger
        }
    }
}
