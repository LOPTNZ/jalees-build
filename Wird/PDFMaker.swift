import UIKit
import WebKit

/// Turns the book summary page (HTML built by the web app) into a paginated A4 PDF.
/// It loads in a hidden web view that serves the same fonts and images as the app (wirdapp://app/).
final class PDFMaker: NSObject, WKNavigationDelegate {
    private var web: WKWebView?
    private var done: ((Data?) -> Void)?
    private var bg: UIColor?

    /// `bg` paints every page edge to edge (margins included), so the summary's colour runs across the whole file.
    func make(html: String, bg: String?, in host: UIView, done: @escaping (Data?) -> Void) {
        self.done = done
        self.bg = bg.flatMap(PDFMaker.color)
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(AppSchemeHandler(), forURLScheme: AppSchemeHandler.scheme)
        let w = WKWebView(frame: CGRect(x: -2000, y: 0, width: 595, height: 842), configuration: cfg)
        w.navigationDelegate = self
        w.isOpaque = false
        w.backgroundColor = .clear
        w.scrollView.backgroundColor = .clear
        host.insertSubview(w, at: 0)
        web = w
        w.loadHTMLString(html, baseURL: URL(string: AppSchemeHandler.scheme + "://app/"))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // wait for the web fonts and images, then a moment for layout to settle
        let js = "await document.fonts.ready; await Promise.all([...document.images].map(i => i.decode ? i.decode().catch(() => 0) : 0)); return 1"
        var fired = false
        let go: () -> Void = { [weak self] in
            if fired { return }
            fired = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self?.render(webView) }
        }
        webView.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { _ in go() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { go() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(nil) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(nil) }

    private func render(_ w: WKWebView) {
        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(w.viewPrintFormatter(), startingAtPageAt: 0)
        let paper = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)
        renderer.setValue(NSValue(cgRect: paper), forKey: "paperRect")
        renderer.setValue(NSValue(cgRect: paper.insetBy(dx: 38, dy: 40)), forKey: "printableRect")
        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, paper, ["Creator": "Jalees"])
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: renderer.numberOfPages))
        let bounds = UIGraphicsGetPDFContextBounds()
        for i in 0..<renderer.numberOfPages {
            UIGraphicsBeginPDFPage()
            if let c = bg, let ctx = UIGraphicsGetCurrentContext() {
                ctx.setFillColor(c.cgColor)
                ctx.fill(bounds)
            }
            renderer.drawPage(at: i, in: bounds)
        }
        UIGraphicsEndPDFContext()
        finish(renderer.numberOfPages > 0 ? data as Data : nil)
    }

    static func color(_ hex: String) -> UIColor? {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return UIColor(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }

    private func finish(_ d: Data?) {
        let cb = done
        done = nil
        web?.removeFromSuperview()
        web = nil
        cb?(d)
    }
}
