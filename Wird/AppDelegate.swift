import UIKit
import UserNotifications
import AVFoundation

@main
final class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        JFont.register()
        NewChapters.register()
        // the phone's voices, read once in the background, so reading aloud starts without a wait
        DispatchQueue.global(qos: .utility).async { _ = AVSpeechSynthesisVoice.speechVoices() }
        // simulator pictures: -JaleesLang en shows the English interface; other checks run in Arabic
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-JaleesLang"), i + 1 < args.count { Lang.set(english: args[i + 1] == "en") }
        else if args.contains("-JaleesRoute") { Lang.set(english: false) }
        if let f = ProcessInfo.processInfo.environment["JALEES_STALLS"] { StallWatch.start(f) }
        AppDirection.apply()
        LangState.onChange = { DispatchQueue.main.async { AppDirection.apply() } }
        // the system's search bars keep their clear button while there are words, not only while typing
        UITextField.appearance(whenContainedInInstancesOf: [UISearchBar.self]).clearButtonMode = .always
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

/// The simulator's walk-through only (JALEES_STALLS): every frame the app itself was late for (over 50 ms), with
/// the time, so the recording's jumps can be told apart: the app busy, or only the build machine drawing slowly.
@MainActor
final class StallWatch: NSObject {
    private static var watch: StallWatch?
    private let file: URL
    private var last: CFTimeInterval = 0
    private var link: CADisplayLink?

    private init(_ path: String) { file = URL(fileURLWithPath: path) }

    static func start(_ path: String) {
        let w = StallWatch(path)
        watch = w
        let l = CADisplayLink(target: w, selector: #selector(frame(_:)))
        l.add(to: .main, forMode: .common)
        w.link = l
    }

    @objc private func frame(_ l: CADisplayLink) {
        defer { last = l.timestamp }
        guard last > 0 else { return }
        let gap = l.timestamp - last
        guard gap > 0.05 else { return }
        // the display link's clock is the system's uptime: written as the wall clock, like the walk-through's marks
        let at = Date().timeIntervalSince1970 - (CACurrentMediaTime() - l.timestamp) - gap
        let line = String(format: "stall %.0f ms from %.3f\n", gap * 1000, at)
        if let h = try? FileHandle(forWritingTo: file) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            h.closeFile()
        } else {
            try? line.write(to: file, atomically: true, encoding: .utf8)
        }
    }
}

/// The system's own pieces (navigation bars, sheets, menus, text fields, the back swipe) go the app's way, not the
/// phone's: an Arabic Jalees on an English phone was laid out left to right around its right-to-left screens. One
/// override on each window, which every view under it inherits (setting it on UIView.appearance() reached every view
/// the app made, and slowed every screen).
@MainActor
enum AppDirection {
    /// every window that comes up later gets it too (the system makes windows of its own for some menus and sheets,
    /// on the iPad especially: without the override they were laid out the phone's way inside an Arabic Jalees)
    private static var watching: NSObjectProtocol?

    static func apply() {
        if watching == nil {
            watching = NotificationCenter.default.addObserver(forName: UIWindow.didBecomeVisibleNotification, object: nil, queue: .main) { n in
                MainActor.assumeIsolated { if let w = n.object as? UIWindow { apply(to: w) } }
            }
        }
        for w in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows) { apply(to: w) }
        // from the next launch the whole process runs in the app's language (dates, the keyboard's first choice)
        let want = Lang.english ? "en" : "ar"
        if (UserDefaults.standard.stringArray(forKey: "AppleLanguages") ?? []).first?.hasPrefix(want) != true {
            UserDefaults.standard.set([want], forKey: "AppleLanguages")
        }
    }

    static func apply(to w: UIWindow) {
        if #available(iOS 17.0, *) {
            let d: UITraitEnvironmentLayoutDirection = Lang.english ? .leftToRight : .rightToLeft
            if w.traitOverrides.contains(UITraitLayoutDirection.self), w.traitOverrides.layoutDirection == d { return }
            w.traitOverrides.layoutDirection = d
        } else {
            w.semanticContentAttribute = Lang.english ? .forceLeftToRight : .forceRightToLeft
        }
    }
}
