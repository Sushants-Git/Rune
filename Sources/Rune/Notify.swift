import Cocoa
import UserNotifications

/// The one thing Rune has to say to you when you are not looking at it: the
/// agent you asked about has stopped.
///
/// Everything here is a no-op without a bundle identifier.
/// `UNUserNotificationCenter` reads the running binary's bundle to work out who
/// is asking, and a bare executable — `swift build` output run straight out of
/// `.build/` — has none, so touching `current()` there traps rather than
/// failing politely. Rune is only ever a real app once `bundle.sh` has wrapped
/// it, and this keeps a debug run from dying on the difference.
enum Notify {
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    /// Ask the first time someone actually arms a bell, rather than at launch.
    ///
    /// A permission sheet in the first second of a terminal's life is a
    /// question about a feature you have not met yet, and the answer you give
    /// to a question you don't understand is "no".
    @MainActor
    static func requestAuthorization() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
            _, error in
            if let error { NSLog("rune: notification authorization failed: \(error)") }
        }
    }

    /// Post one, tagged with the workspace it came from so a click can go there.
    @MainActor
    static func post(title: String, body: String, workspace: UUID) {
        guard isAvailable else {
            bounce()
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = [workspaceKey: workspace.uuidString]

        // No trigger means "now". A time-interval trigger of zero is rejected.
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            guard let error else { return }
            NSLog("rune: notification failed: \(error)")
            // Refused permission, most likely. Bouncing is a worse answer than
            // a banner but a much better one than silence — you asked to be
            // told, and this is the last way left to tell you.
            DispatchQueue.main.async { MainActor.assumeIsolated { bounce() } }
        }
    }

    @MainActor
    private static func bounce() {
        NSApp.requestUserAttention(.informationalRequest)
    }

    private static let workspaceKey = "workspace"

    /// The workspace a notification was about, if it was one of ours.
    static func workspace(of notification: UNNotification) -> UUID? {
        (notification.request.content.userInfo[workspaceKey] as? String).flatMap(UUID.init)
    }
}
