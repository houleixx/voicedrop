import UIKit
import UserNotifications

/// APNs registration + device-token upload. The server (voicedrop-agent worker)
/// pushes "文章已生成" when the async miner finishes, and ops alerts to the admin —
/// both need the device token stored server-side at `users/<sub>/push-token.json`.
///
/// Flow: app launch → request notification permission (one system dialog, once)
/// → registerForRemoteNotifications → didRegister hands us the token → PUT it to
/// the files API (single-segment ASCII name, sails through the upload guard).
/// Re-uploads on every launch (token can rotate; the PUT is tiny and idempotent).
final class PushRegistrar: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        Task {
            let ok = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            if ok { await MainActor.run { application.registerForRemoteNotifications() } }
        }
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { await Self.upload(token: token) }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        EngineRecorder.trace("push: register failed \(error.localizedDescription)")
    }

    /// Show pushes as banners even when the app is foreground (e.g. 报警 while
    /// the admin happens to be in the app).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// Tap on a notification: the payload carries a `link` deep link
    /// (voicedrop://article/<stem> for「文章已生成」) — route straight to the
    /// article instead of dumping the user on the list.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let link = info["link"] as? String, let url = URL(string: link) {
            Task { @MainActor in AppRouter.shared.handle(url) }
        }
        completionHandler()
    }

    @MainActor
    private static func upload(token: String) async {
        let bearer = AuthStore.shared.bearer
        guard !bearer.isEmpty,
              let url = URL(string: "\(API.filesBase.absoluteString)/upload/push-token.json") else { return }
        // env 决定 worker 打 APNs 生产还是沙箱网关：Debug 真机 = sandbox。
        #if DEBUG
        let env = "dev"
        #else
        let env = "prod"
        #endif
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setBearer(bearer)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "token": token, "env": env, "updatedAt": ISO8601DateFormatter().string(from: Date()),
        ])
        _ = try? await URLSession.shared.data(for: req)
    }
}
