import AppKit
import Foundation

@MainActor
final class SensitiveClipboard {
    static let shared = SensitiveClipboard()

    var autoClearTimeoutSeconds: TimeInterval = 30

    private var clearTask: Task<Void, Never>?

    private init() {}

    func copySensitiveText(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        scheduleAutoClear(expectedChangeCount: pasteboard.changeCount)
    }

    private func scheduleAutoClear(expectedChangeCount: Int) {
        clearTask?.cancel()

        let timeout = autoClearTimeoutSeconds
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
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount == expectedChangeCount else {
            return
        }
        pasteboard.clearContents()
    }
}
