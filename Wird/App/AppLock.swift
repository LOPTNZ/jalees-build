import SwiftUI
import UIKit
import LocalAuthentication

/// قفل جليس بـ Face ID (answers-round2 س67 «بعدين»): when on, Jalees hides behind a cover as soon as it leaves the
/// screen (so the app switcher shows nothing), and opens with Face ID, Touch ID or the phone's passcode. A short grace
/// period you choose skips the lock after a quick trip out.
@MainActor
final class AppLock: ObservableObject {
    static let shared = AppLock()

    @Published private(set) var locked = false
    @Published var failed = false
    private var window: UIWindow?
    private var leftAt: Date?
    private var scene: UIWindowScene?
    private var coverToken = 0
    /// a link that came in while locked
    private var pending: URL?
    private var asking = false

    var enabled: Bool {
        get { UserDefaults.standard.bool("lock.on") }
        set {
            UserDefaults.standard.set(newValue, forKey: "lock.on")
            objectWillChange.send()
            if !newValue {
                locked = false
                leftAt = nil
                pending = nil
                if window?.isHidden == false { uncover() }
            }
            // the widgets show a locked card (and the reminder names no book) while the lock is on
            WidgetFeed.update()
            Reminder.sync()
        }
    }
    /// seconds away before it locks again: 0, 60, 300
    var grace: Double {
        get { UserDefaults.standard.double(forKey: "lock.grace") }
        set { UserDefaults.standard.set(newValue, forKey: "lock.grace"); objectWillChange.send() }
    }

    /// What the phone can open with, for the settings' wording.
    static var method: String {
        let c = LAContext()
        _ = c.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch c.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        default: return "رمز الجوال"
        }
    }

    /// Turning it on asks once, so a phone without a passcode can't lock you out.
    func turnOn(_ on: Bool) {
        guard on else { enabled = false; return }
        let c = LAContext()
        var err: NSError?
        guard c.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            Toaster.show("فعّل رمز الجوال أو Face ID أول من إعدادات الجوال")
            objectWillChange.send()
            return
        }
        c.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "تأكيد قفل جليس") { ok, _ in
            Task { @MainActor in
                self.enabled = ok
                if ok { Toaster.show("جليس صار يتقفل بـ \(Self.method)") }
            }
        }
    }

    // MARK: the scene's comings and goings

    func launched(_ scene: UIWindowScene) {
        self.scene = scene
        // built now (and left hidden) so the first time it is needed it is already drawn, before the app switcher's snapshot
        prepareWindow(scene)
        guard enabled else { return }
        cover()
        locked = true
        unlock()
    }

    /// The scene is about to stop being the active one (Control Center, a notification pulled down, the app switcher):
    /// the cover goes up at once, because the system takes its snapshot about now. It makes nobody authenticate again.
    func resigning(_ scene: UIWindowScene) {
        self.scene = scene
        guard enabled, !asking else { return }
        if !locked, leftAt == nil { leftAt = Date() }
        cover()
    }

    /// The app is really in the background. `leftAt` was set a moment earlier, when the scene resigned.
    func wentAway(_ scene: UIWindowScene) {
        self.scene = scene
        guard enabled, !asking else { return }
        if !locked, leftAt == nil { leftAt = Date() }
        cover()
    }

    /// Coming back from the background: inside the grace period the unlocked state is kept, otherwise it locks again.
    func cameBack(_ scene: UIWindowScene) {
        self.scene = scene
        guard enabled, !asking else { return }
        if !locked, let t = leftAt, Date().timeIntervalSince(t) < grace { return }  // becameActive takes the cover off
        locked = true
        cover()
        unlock()
    }

    /// The scene is active again: when nobody needs to authenticate (the lock is off, or a short trip out inside the
    /// grace period, or only Control Center was pulled down) the cover comes off. A locked app stays covered.
    func becameActive(_ scene: UIWindowScene) {
        guard enabled else {
            locked = false
            leftAt = nil
            if window?.isHidden == false { uncover() }
            return
        }
        guard !asking, !locked else { return }
        leftAt = nil
        uncover()
    }

    private func prepareWindow(_ scene: UIWindowScene) {
        guard window == nil else { return }
        let w = UIWindow(windowScene: scene)
        w.windowLevel = .alert + 1
        let host = UIHostingController(rootView: LockView().environment(\.look, Appearance.shared.look).environment(\.layoutDirection, Lang.direction))
        host.view.backgroundColor = .clear
        w.rootViewController = host
        w.isHidden = true
        window = w
    }

    /// The cover goes up. It doesn't change `locked`: that says whether authentication is needed, the cover also
    /// hides the app from the app switcher while it is not.
    private func cover() {
        if window == nil, let s = scene { prepareWindow(s) }
        coverToken += 1
        window?.layer.removeAllAnimations()
        window?.alpha = 1
        window?.isHidden = false
    }

    private func uncover() {
        coverToken += 1
        let token = coverToken
        locked = false
        UIView.animate(withDuration: 0.25, animations: { self.window?.alpha = 0 }, completion: { _ in
            // a cover put up again meanwhile stays
            guard token == self.coverToken else { return }
            self.window?.isHidden = true
            self.window?.alpha = 1
        })
    }

    func unlock() {
        guard locked, !asking else { return }
        asking = true
        failed = false
        let c = LAContext()
        c.localizedCancelTitle = "لاحقًا"
        c.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "افتح جليس") { ok, _ in
            Task { @MainActor in
                self.asking = false
                if ok {
                    self.leftAt = nil
                    self.uncover()
                    // a link that arrived while it was locked (a widget's tap, a shared page) opens now
                    if let u = self.pending { self.pending = nil; DeepLink.handle(u) }
                } else {
                    self.failed = true
                }
            }
        }
    }

    /// A link to open while the app is locked is kept until it is unlocked; true when it was kept.
    func hold(_ url: URL) -> Bool {
        guard enabled, locked else { return false }
        pending = url
        return true
    }
}

private extension UserDefaults {
    func bool(_ k: String) -> Bool { bool(forKey: k) }
}

/// The cover: Jalees's name, and a button to try again.
private struct LockView: View {
    @ObservedObject private var lock = AppLock.shared
    @Environment(\.look) private var L
    var body: some View {
        ZStack {
            Color(L.bg).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "lock.fill").font(.system(size: 30, weight: .semibold)).foregroundStyle(Color(L.primary))
                Text("جَليس").font(JFont.display(44, .bold)).foregroundStyle(Color(L.primary))
                if lock.failed {
                    Button { lock.unlock() } label: { Label("افتح بـ " + AppLock.method, systemImage: "faceid").padding(.horizontal, 8) }
                        .buttonStyle(JButtonStyle(look: L, primary: true))
                }
            }
        }
    }
}
