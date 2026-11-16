import UIKit
import WebKit

/// Sites behind Cloudflare, and sites that want you signed in (answers-round2 س16، س25): the page opens inside Jalees,
/// you pass the check (or sign in) once, and its cookies go to the app's own downloads, so chapters come normally
/// after. Pages are always asked for with the same iPhone Safari identity, which is what the check is tied to.
@MainActor
enum SiteGate {
    private static var open: GateController?
    /// A check that was cancelled, per site: for a few minutes the site is not asked again, so a long download
    /// does not throw the sheet up again for every chapter.
    private static var cancelled: [String: Date] = [:]

    /// True while a cancelled check on this site is still remembered (downloads stop on it).
    static func isBlocked(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), let t = cancelled[host] else { return false }
        if t > Date() { return true }
        cancelled[host] = nil
        return false
    }

    /// A refused page while the app is on screen: the check, then true when it passed.
    static func pass(_ url: URL) async -> Bool {
        guard UIApplication.shared.applicationState == .active, open == nil, !isBlocked(url), let h = NovelBridge.host else { return false }
        return await withCheckedContinuation { cont in
            let g = GateController(url: url, mode: .check) { ok in
                if !ok, let host = url.host?.lowercased() { cancelled[host] = Date().addingTimeInterval(300) }
                cont.resume(returning: ok)
            }
            open = g
            let nav = UINavigationController(rootViewController: g)
            nav.presentationController?.delegate = g
            NovelBridge.top(h).present(nav, animated: true)
        }
    }

    /// «دخول للموقع» from the browse list: the site's page; «تم» keeps whatever you signed in with.
    static func signIn(_ home: String) {
        guard let u = URL(string: home), let h = NovelBridge.host, open == nil else { return }
        // signing in on purpose: the site is asked again from now on
        if let host = u.host?.lowercased() { cancelled[host] = nil }
        let g = GateController(url: u, mode: .signIn) { _ in }
        open = g
        let nav = UINavigationController(rootViewController: g)
        nav.presentationController?.delegate = g
        NovelBridge.top(h).present(nav, animated: true)
    }

    fileprivate static func closed() { open = nil }

    /// The web view's cookies (where the check or the sign-in happened) copied to the app's downloads.
    static func syncCookies() async {
        let all: [HTTPCookie] = await withCheckedContinuation { c in WKWebsiteDataStore.default().httpCookieStore.getAllCookies { c.resume(returning: $0) } }
        for k in all { HTTPCookieStorage.shared.setCookie(k) }
    }
}

private final class GateController: UIViewController, WKNavigationDelegate, UIAdaptivePresentationControllerDelegate {
    enum Mode { case check, signIn }
    let url: URL
    let mode: Mode
    let done: (Bool) -> Void
    private var web: WKWebView!
    private var finished = false
    private var poll: Timer?

    init(url: URL, mode: Mode, done: @escaping (Bool) -> Void) {
        self.url = url
        self.mode = mode
        self.done = done
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("no storyboard") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        web = WKWebView(frame: view.bounds, configuration: cfg)
        web.customUserAgent = Fetcher.ua
        web.navigationDelegate = self
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(web)
        title = mode == .check ? "تحقق الموقع" : (url.host ?? "الموقع")
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: mode == .check ? "إلغاء" : "تم", style: mode == .check ? .plain : .done, target: self, action: #selector(close))
        if mode == .check {
            let l = UILabel()
            l.text = "الموقع يتحقق إنك مو روبوت. إذا طلع لك تحقق حلّه، وأكمل لحالي.".tr
            l.numberOfLines = 0
            l.font = .systemFont(ofSize: 13)
            l.textColor = .secondaryLabel
            l.textAlignment = .center
            l.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 44)
            navigationItem.prompt = nil
            web.scrollView.contentInset.top = 0
            view.addSubview(l)
            l.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                l.leftAnchor.constraint(equalTo: view.leftAnchor, constant: 16), l.rightAnchor.constraint(equalTo: view.rightAnchor, constant: -16),
                l.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8)
            ])
            // the check passes on its own most of the time: look every second
            poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.look() } }
        }
        web.load(URLRequest(url: url))
    }

    private func look() {
        web.evaluateJavaScript("document.title + ' | ' + (document.querySelector('#challenge-form, #cf-challenge-running, .cf-turnstile, #challenge-stage') ? 'challenge' : 'ok')") { [weak self] v, _ in
            guard let self = self, let s = v as? String else { return }
            if !s.lowercased().contains("just a moment"), !s.contains("challenge"), !s.lowercased().contains("attention required") {
                self.finish(true)
            }
        }
    }

    @objc private func close() { finish(mode == .signIn) }

    /// Swiping the sheet down closes it too: it counts as the same as the cancel button, so the waiting download
    /// is answered and the next check can open.
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        finish(mode == .signIn, dismissed: true)
    }

    deinit { poll?.invalidate() }

    // runs once: the button, the swipe and the poll can all arrive
    private func finish(_ ok: Bool, dismissed: Bool = false) {
        guard !finished else { return }
        finished = true
        poll?.invalidate()
        poll = nil
        Task { @MainActor in
            await SiteGate.syncCookies()
            if !dismissed { self.dismiss(animated: true) }
            SiteGate.closed()
            self.done(ok)
        }
    }
}
