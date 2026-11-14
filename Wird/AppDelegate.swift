import UIKit
import UserNotifications

@main
final class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        JFont.register()
        NewChapters.register()
        // simulator pictures: -JaleesLang en shows the English interface; other checks run in Arabic
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-JaleesLang"), i + 1 < args.count { Lang.set(english: args[i + 1] == "en") }
        else if args.contains("-JaleesRoute") { Lang.set(english: false) }
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
    }

    // While the app is open the page already shows the countdown toast; reminders still show as a banner.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if notification.request.identifier.hasPrefix("wird.cd") {
            completionHandler([])
        } else {
            completionHandler([.banner, .list, .sound])
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        // a new chapters' alert: that novel's page
        let info = response.notification.request.content.userInfo
        if let id = info["novel"] as? Int {
            let book = info["book"] as? String ?? ""
            Task { @MainActor in
                Present.shared.modal = nil
                Router.shared.openNovel(id, book: book)
            }
        }
        completionHandler()
    }
}
