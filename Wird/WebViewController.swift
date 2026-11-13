import UIKit
import WebKit

/// The whole interface is the bundled web app (www/index.html), served from wirdapp://app/ so it has a
/// stable origin. Native features are reached through the "wird" message handler (see Bridge.swift).
final class WebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    private(set) var webView: WKWebView!
    private let bridge = Bridge()
    private var ready = false
    private var scanner: AnyObject?
    private var lightBar = false
    private var pdfMaker: PDFMaker?

    override var preferredStatusBarStyle: UIStatusBarStyle { lightBar ? .lightContent : .default }
    /// The library stays upright; only the reader turns sideways (unless its lock is on).
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }
    var pendingURL: URL?

    override func loadView() {
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(AppSchemeHandler(), forURLScheme: AppSchemeHandler.scheme)
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: "wird")
        installBootScript(cfg.userContentController)

        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.isOpaque = false
        let bg = UIColor(named: "LaunchBG") ?? .systemBackground
        wv.backgroundColor = bg
        wv.scrollView.backgroundColor = bg
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        wv.scrollView.bounces = false
        wv.allowsLinkPreview = false
        wv.allowsBackForwardNavigationGestures = false
        if #available(iOS 16.4, *) { wv.isInspectable = true }
        webView = wv
        bridge.host = self
        view = wv
    }

    /// Hands the saved library to the page before any of its scripts run.
    private func installBootScript(_ uc: WKUserContentController) {
        uc.removeAllUserScripts()
        let b64 = Store.shared.loadStateData()?.base64EncodedString() ?? ""
        let ver = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let ed = Bundle.main.object(forInfoDictionaryKey: "WirdEdition") as? String ?? "demo"
        let js = "window.__WIRD_B64=\"\(b64)\";window.__WIRD_APP={version:\"\(ver)\",edition:\"\(ed)\"};"
        uc.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if let url = URL(string: AppSchemeHandler.scheme + "://app/index.html") {
            webView.load(URLRequest(url: url))
        }
    }

    // MARK: navigation

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        if let u = pendingURL {
            pendingURL = nil
            handleDeepLink(u)
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false
        installBootScript(webView.configuration.userContentController)
        webView.reload()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.cancel)
            return
        }
        if scheme == AppSchemeHandler.scheme || scheme == "about" || scheme == "data" || scheme == "blob" {
            decisionHandler(.allow)
            return
        }
        if ["http", "https", "mailto", "tel"].contains(scheme) {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let u = navigationAction.request.url, ["http", "https"].contains(u.scheme?.lowercased() ?? "") {
            UIApplication.shared.open(u)
        }
        return nil
    }

    // MARK: called by the scene

    func handleDeepLink(_ url: URL) {
        guard ready else {
            pendingURL = url
            return
        }
        var o: [String: String] = [:]
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.forEach { o[$0.name] = $0.value ?? "" }
        if url.host == "session" { o["session"] = "1" }
        guard let data = try? JSONSerialization.data(withJSONObject: o), let s = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.wirdOpen&&window.wirdOpen(\(s))", completionHandler: nil)
    }

    func resumed() {
        guard ready else { return }
        webView.evaluateJavaScript("window.wirdResume&&window.wirdResume()", completionHandler: nil)
    }

    // MARK: used by the bridge

    /// Light status bar text over the dark cover band and the session screen.
    func setBar(light: Bool) {
        guard lightBar != light else { return }
        lightBar = light
        UIView.animate(withDuration: 0.25) { self.setNeedsStatusBarAppearanceUpdate() }
    }

    func setTheme(_ t: String?) {
        let style: UIUserInterfaceStyle = t == "dark" ? .dark : (t == "light" ? .light : .unspecified)
        view.window?.overrideUserInterfaceStyle = style
        setNeedsStatusBarAppearanceUpdate()
    }

    /// A book summary as a PDF, then the share sheet (Save to Files, Books, AirDrop, Print…).
    func makePDF(_ o: [String: Any], done: @escaping (Bool) -> Void) {
        guard let html = o["html"] as? String else {
            done(false)
            return
        }
        let name = (o["name"] as? String) ?? "Jalees.pdf"
        let m = PDFMaker()
        pdfMaker = m
        m.make(html: html, bg: o["bg"] as? String, in: view) { [weak self] data in
            self?.pdfMaker = nil
            guard let self = self, let data = data else {
                done(false)
                return
            }
            self.shareData(data, name: name, done: done)
        }
    }

    /// Share sheet: Save to Files, AirDrop, Save Image…
    func share(_ a: Any?, done: @escaping (Bool) -> Void) {
        guard let o = a as? [String: Any], let name = o["name"] as? String, let b64 = o["b64"] as? String,
              let data = Data(base64Encoded: b64) else {
            done(false)
            return
        }
        shareData(data, name: name, done: done)
    }

    func shareData(_ data: Data, name: String, done: @escaping (Bool) -> Void) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name.replacingOccurrences(of: "/", with: "-"))
        do { try data.write(to: url, options: .atomic) } catch {
            done(false)
            return
        }
        let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        av.completionWithItemsHandler = { _, completed, _, _ in done(completed) }
        av.popoverPresentationController?.sourceView = view
        av.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.maxY - 80, width: 1, height: 1)
        topPresenter().present(av, animated: true)
    }

    /// One barcode (a String), or with `multi` a run of them (an array of Strings) until «إنهاء».
    func scan(multi: Bool = false, done: @escaping (Any?) -> Void) {
        if #available(iOS 16.0, *) {
            let s = BarcodeScanner()
            s.multi = multi
            scanner = s
            s.present(from: topPresenter()) { [weak self] code in
                self?.scanner = nil
                done(code)
            }
        } else {
            done(nil)
        }
    }

    /// The small book-site browser; replies with the imported page data, or nil when closed.
    func browse(_ o: [String: Any], done: @escaping ([String: Any]?) -> Void) {
        let b = BookBrowser(query: o["q"] as? String ?? "", site: o["site"] as? Int ?? 0, done: done)
        let nav = UINavigationController(rootViewController: b)
        nav.modalPresentationStyle = .pageSheet
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        nav.presentationController?.delegate = b
        topPresenter().present(nav, animated: true)
    }

    private func topPresenter() -> UIViewController {
        var v: UIViewController = self
        while let p = v.presentedViewController { v = p }
        return v
    }
}

/// Serves the bundled web app and the stored images (wirdapp://app/img/<id>).
final class AppSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "wirdapp"
    private let root: URL = (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("www", isDirectory: true).standardizedFileURL

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        var path = url.path
        if path.isEmpty || path == "/" { path = "/index.html" }
        var data: Data?
        var mime = "application/octet-stream"
        if path.hasPrefix("/img/") {
            data = Store.shared.imageData(String(path.dropFirst(5)))
            if let d = data { mime = Store.mime(of: d) }
        } else if path.hasPrefix("/epub/") {
            // a file inside an EPUB book: /epub/<book>/<path inside the book>
            let rest = String(path.dropFirst(6))
            if let slash = rest.firstIndex(of: "/") {
                let inner = String(rest[rest.index(after: slash)...])
                data = EpubStore.resource(String(rest[..<slash]), inner)
                mime = AppSchemeHandler.mime((inner as NSString).pathExtension)
            }
        } else if path.hasPrefix("/userfonts/") {
            // fonts the owner added for reading (FontStore)
            let name = String(path.dropFirst(11)).replacingOccurrences(of: "/", with: "")
            let file = FontStore.dir.appendingPathComponent(name)
            data = try? Data(contentsOf: file)
            mime = AppSchemeHandler.mime(file.pathExtension)
        } else {
            let file = root.appendingPathComponent(String(path.dropFirst())).standardizedFileURL
            if file.path.hasPrefix(root.path) { data = try? Data(contentsOf: file) }
            mime = AppSchemeHandler.mime(file.pathExtension)
        }
        var headers = ["Content-Type": mime, "Cache-Control": "no-store", "Access-Control-Allow-Origin": "*"]
        if let d = data {
            headers["Content-Length"] = String(d.count)
            if let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) {
                task.didReceive(resp)
                task.didReceive(d)
                task.didFinish()
            }
        } else if let resp = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: headers) {
            task.didReceive(resp)
            task.didReceive(Data())
            task.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    static func mime(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "woff": return "font/woff"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "xhtml": return "application/xhtml+xml"
        case "svg": return "image/svg+xml"
        default: return "application/octet-stream"
        }
    }
}
