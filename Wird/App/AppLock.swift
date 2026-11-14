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
    private var asking = false

    var enabled: Bool {
        get { UserDefaults.standard.bool("lock.on") }
        set { UserDefaults.standard.set(newValue, forKey: "lock.on"); objectWillChange.send() }
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
        guard enabled else { return }
        cover(scene)
        unlock()
    }

    func wentAway(_ scene: UIWindowScene) {
        guard enabled, !asking else { return }
        leftAt = Date()
        cover(scene)
    }

    func cameBack(_ scene: UIWindowScene) {
        guard enabled, !asking else { return }
        if let t = leftAt, Date().timeIntervalSince(t) < grace, !locked {
            uncover()
            return
        }
        cover(scene)
        unlock()
    }

    private func cover(_ scene: UIWindowScene) {
        if window == nil {
            let w = UIWindow(windowScene: scene)
            w.windowLevel = .alert + 1
            let host = UIHostingController(rootView: LockView().environment(\.look, Appearance.shared.look).environment(\.layoutDirection, .rightToLeft))
            host.view.backgroundColor = .clear
            w.rootViewController = host
            window = w
        }
        window?.isHidden = false
        locked = true
    }

    private func uncover() {
        UIView.animate(withDuration: 0.25, animations: { self.window?.alpha = 0 }, completion: { _ in
            self.window?.isHidden = true
            self.window?.alpha = 1
        })
        locked = false
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
                if ok { self.leftAt = nil; self.uncover() } else { self.failed = true }
            }
        }
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
