import Foundation
import SwiftUI
import Observation

/// Drives the toast at the bottom of the main window.
@MainActor
@Observable
final class CopyFeedbackCenter {
    struct Toast: Equatable {
        enum Style: Equatable {
            case success
            case synced
            case restored
        }

        let id = UUID()
        let message: String
        let style: Style
        let actionTitle: String?

        static func == (lhs: Toast, rhs: Toast) -> Bool {
            lhs.id == rhs.id
        }
    }

    static let shared = CopyFeedbackCenter()

    private(set) var current: Toast?
    private var action: (@MainActor () -> Void)?
    private var dismissTask: Task<Void, Never>?

    var currentMessage: String? {
        current?.message
    }

    private init() {}

    func show(_ message: String? = nil, duration: TimeInterval = 1.4) {
        show(message ?? L("Copied"), style: .success, duration: duration)
    }

    func show(
        _ message: String,
        style: Toast.Style,
        duration: TimeInterval = 2.4,
        actionTitle: String? = nil,
        action: (@MainActor () -> Void)? = nil
    ) {
        current = Toast(message: message, style: style, actionTitle: action == nil ? nil : actionTitle)
        self.action = action
        // Toasts are visual only; VoiceOver users hear the same message.
        AccessibilityNotification.Announcement(message).post()

        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else {
                return
            }
            self?.dismiss()
        }
    }

    func runAction() {
        let action = self.action
        dismiss()
        action?()
    }

    func dismiss() {
        dismissTask?.cancel()
        current = nil
        action = nil
    }
}
