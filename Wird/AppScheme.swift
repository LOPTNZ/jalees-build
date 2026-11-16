import UIKit
import WebKit

/// Serves the app's own pages to its web views (the reader's text page, the site parsers, the PDF) and the stored
/// images (wirdapp://app/img/<id>), files inside EPUB books and the owner's fonts.
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
                let book = String(rest[..<slash])
                let kind = AppSchemeHandler.mime((inner as NSString).pathExtension)
                // unpacking a picture takes time: it is done off the main thread, and the answer is given only if
                // the page has not cancelled the request meanwhile (a stopped task must not be called)
                pending.insert(ObjectIdentifier(task))
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let d = EpubStore.resource(book, inner)
                    DispatchQueue.main.async {
                        guard let self = self, self.pending.remove(ObjectIdentifier(task)) != nil else { return }
                        self.answer(task, url, d, kind)
                    }
                }
                return
            }
        } else if path.hasPrefix("/userfonts/") {
            // fonts the owner added for reading (FontStore)
            let name = String(path.dropFirst(11)).replacingOccurrences(of: "/", with: "")
            let file = FontStore.dir.appendingPathComponent(name)
            data = try? Data(contentsOf: file)
            mime = AppSchemeHandler.mime(file.pathExtension)
        } else {
            let file = root.appendingPathComponent(String(path.dropFirst())).standardizedFileURL
            // with the slash: a folder named «www-other» next to «www» is not inside it
            if file.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/") { data = try? Data(contentsOf: file) }
            mime = AppSchemeHandler.mime(file.pathExtension)
        }
        answer(task, url, data, mime)
    }

    /// the requests being answered off the main thread (touched on the main thread only)
    private var pending = Set<ObjectIdentifier>()

    private func answer(_ task: WKURLSchemeTask, _ url: URL, _ data: Data?, _ mime: String) {
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

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) { pending.remove(ObjectIdentifier(task)) }

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
