import AppKit
import Data
import Domain
import Foundation
import UserNotifications

/// Expired and soon-to-expire entries of the open database, for the unlock reminder and the sidebar badge.
public struct ExpirySummary: Equatable, Sendable {
    public let expired: Int
    public let expiringSoon: Int
    public let warnDays: Int

    public var isEmpty: Bool { expired + expiringSoon == 0 }

    public init(entries: [VaultEntry], warnDays: Int, now: Date = Date()) {
        let limit = now.addingTimeInterval(TimeInterval(warnDays) * 86_400)
        var expired = 0
        var soon = 0
        for entry in entries where !entry.isTrashed {
            guard let expiresAt = entry.expiresAt else {
                continue
            }
            if expiresAt < now {
                expired += 1
            } else if expiresAt <= limit {
                soon += 1
            }
        }
        self.expired = expired
        self.expiringSoon = soon
        self.warnDays = warnDays
    }

    var windowText: String {
        switch warnDays {
        case 7: return L("this week")
        case 14: return L("in the next 2 weeks")
        case 30: return L("in the next 30 days")
        default: return L("in the next \(warnDays) days")
        }
    }

    /// Counts only: notifications show on the lock screen, so entry titles never go there.
    func notificationContent(databaseName: String) -> (title: String, body: String) {
        let passwords = expired > 0 ? L("\(expired) passwords") : L("\(expiringSoon) passwords")
        if expired > 0 {
            // Verb-only plural ("has expired" / "have expired"), so the database name can sit in the middle.
            let verb = L("\(expired) have expired")
            let first = L("\(passwords) in \(databaseName) \(verb)")
            guard expiringSoon > 0 else {
                return (L("Passwords expired"), first + ".")
            }
            let more = L("\(expiringSoon) more expire")
            return (L("Passwords expired"), L("\(first), and \(more) \(windowText)."))
        }
        let verb = L("\(expiringSoon) expire") + " " + windowText
        return (L("Passwords expiring soon"), L("\(passwords) in \(databaseName) \(verb)") + ".")
    }

    var bannerText: String {
        if expired > 0 {
            var text = L("\(expired) passwords have expired")
            if expiringSoon > 0 {
                text += " · \(expiringSoon) " + L("\(expiringSoon) expire") + " " + windowText
            }
            return text
        }
        return L("\(expiringSoon) passwords expire") + " " + windowText
    }
}

/// Posts the expiry reminder as a macOS notification; clicking it opens Password Health.
@MainActor
public final class ExpiryNotifier: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = ExpiryNotifier()

    private static let identifier = "keemac.expiry"

    /// The unbundled debug binary has no bundle identifier, and UserNotifications crashes without one.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil || UITesting.isActive ? nil : UNUserNotificationCenter.current()
    }

    /// Call at launch so a click on a notification that launched the app is delivered.
    public func activate() {
        center?.delegate = self
    }

    func post(_ summary: ExpirySummary, databaseName: String) {
        guard let center, !summary.isEmpty else {
            return
        }
        let content = UNMutableNotificationContent()
        let text = summary.notificationContent(databaseName: databaseName)
        content.title = text.title
        content.body = text.body
        let request = UNNotificationRequest(identifier: Self.identifier, content: content, trigger: nil)
        Task {
            guard (try? await center.requestAuthorization(options: [.alert])) == true else {
                return
            }
            try? await center.add(request)
        }
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await MainActor.run {
            NotificationCenter.default.post(name: AppCommand.openPasswordHealth, object: nil)
        }
    }
}
