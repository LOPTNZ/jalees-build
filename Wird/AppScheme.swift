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
