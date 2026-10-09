import AppKit
import Foundation

@MainActor
public final class SensitiveClipboard {
    public static let shared = SensitiveClipboard(pasteboard: UITesting.isActive ? UITesting.pasteboard : .general)

    private var clearTask: Task<Void, Never>?
    /// Pasteboard change count right after KeeMac put a secret there.
    private var sensitiveChangeCount: Int?
    private let settingsStore: AppSettingsStore
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general, settingsStore: AppSettingsStore = .shared) {
        self.pasteboard = pasteboard
        self.settingsStore = settingsStore
    }

    /// Copies a secret and schedules the auto-clear. Returns the feedback text
    /// ("Password copied · clears in 30 seconds") for views that show their own toast.
    /// `label` is already localized ("Password"); nil shows plain "Copied".
    @discardableResult
    func copySensitiveText(_ value: String, label: String? = nil, showsToast: Bool = true) -> String {
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        sensitiveChangeCount = pasteboard.changeCount
        scheduleAutoClear(expectedChangeCount: pasteboard.changeCount)
        let message = feedbackMessage(label: label, clears: true)
        if showsToast {
            CopyFeedbackCenter.shared.show(message, duration: 2.4)
        }
        return message
    }

    func copyPlainText(_ value: String, label: String) {
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        CopyFeedbackCenter.shared.show(feedbackMessage(label: label, clears: false), duration: 2.4)
    }

    /// Clears a secret KeeMac copied, unless something else has been copied since (called on lock and quit).
    public func clearSensitiveContents() {
        clearTask?.cancel()
        guard let sensitiveChangeCount else {
            return
        }
        clearIfUnchanged(expectedChangeCount: sensitiveChangeCount)
    }

    private func feedbackMessage(label: String?, clears: Bool) -> String {
        let base = label.map { L("\($0) copied") } ?? L("Copied")
        let timeout = settingsStore.clipboardAutoClearTimeoutSeconds
        guard clears, timeout > 0 else {
            return base
        }
        let seconds = Int(timeout)
        let interval = seconds < 60 ? L("\(seconds) seconds") : L("\(seconds / 60) minutes")
        return L("\(base) · clears in \(interval)")
    }

    private func scheduleAutoClear(expectedChangeCount: Int) {
        clearTask?.cancel()

        let timeout = settingsStore.clipboardAutoClearTimeoutSeconds
        guard timeout > 0 else {
            return
        }

        clearTask = Task { [weak self] in
            let nanoseconds = UInt64(timeout * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else {
                return
            }
            await MainActor.run {
                guard let self else {
                    return
                }
                self.clearIfUnchanged(expectedChangeCount: expectedChangeCount)
            }
        }
    }

    private func clearIfUnchanged(expectedChangeCount: Int) {
        guard pasteboard.changeCount == expectedChangeCount else {
            return
        }
        pasteboard.clearContents()
        sensitiveChangeCount = nil
    }
}
