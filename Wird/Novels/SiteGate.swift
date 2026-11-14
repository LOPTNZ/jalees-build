import UIKit
import WebKit

/// Sites behind Cloudflare, and sites that want you signed in (answers-round2 س16، س25): the page opens inside Jalees,
/// you pass the check (or sign in) once, and its cookies go to the app's own downloads, so chapters come normally
/// after. Pages are always asked for with the same iPhone Safari identity, which is what the check is tied to.
@MainActor
enum SiteGate {
    private static var open: GateController?

    /// A refused page while the app is on screen: the check, then true when it passed.
    static func pass(_ url: URL) async -> Bool {
        guard UIApplication.shared.applicationState == .active, open == nil, let h = NovelBridge.host else { return false }
        return await withCheckedContinuation { cont in
            let g = GateController(url: url, mode: .check) { ok in cont.resume(returning: ok) }
            open = g
            NovelBridge.top(h).present(UINavigationController(rootViewController: g), animated: true)
        }
    }

    /// «دخول للموقع» from the browse list: the site's page; «تم» keeps whatever you signed in with.
    static func signIn(_ home: String) {
        guard let u = URL(string: home), let h = NovelBridge.host, open == nil else { return }
        let g = GateController(url: u, mode: .signIn) { _ in }
        open = g
        NovelBridge.top(h).present(UINavigationController(rootViewController: g), animated: true)
    }

    fileprivate static func closed() { open = nil }

    /// The web view's cookies (where the check or the sign-in happened) copied to the app's downloads.
    static func syncCookies() async {
        let all: [HTTPCookie] = await withCheckedContinuation { c in WKWebsiteDataStore.default().httpCookieStore.getAllCookies { c.resume(returning: $0) } }
        for k in all { HTTPCookieStorage.shared.setCookie(k) }
    }
}

private final class GateController: UIViewController, WKNavigationDelegate {
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

    private func finish(_ ok: Bool) {
        guard !finished else { return }
        finished = true
        poll?.invalidate()
        Task { @MainActor in
            await SiteGate.syncCookies()
            self.dismiss(animated: true)
            SiteGate.closed()
            self.done(ok)
        }
    }
}
