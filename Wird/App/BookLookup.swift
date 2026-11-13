import UIKit

/// Finding a book online (the web app's 03-lookup.js, run as it is in the hidden engine page; see tools/make_lookup.py):
/// Goodreads, Open Library, Google Books and Abjjad; editions; covers; barcodes. Results are the web app's objects:
/// {src, title, author, pages, approx, lang, year, publisher, isbn, format, minutes, cover, thumb, grWork, olWork, url, exact, mark}.
@MainActor
enum BookLookup {
    typealias Item = [String: Any]

    private static var key: String { Library.shared.state.settings.raw.str("gbKey") }
    static let sourceNames = ["gr": "Goodreads", "ol": "Open Library", "gb": "Google Books", "abj": "أبجد", "web": "من الويب"]

    /// A typed or scanned ISBN, or "" when the text is not one.
    static func isbn(_ q: String) async -> String {
        (await SourceEngine.shared.lookup("return LookupISBN(q)", ["q": q]) as? String) ?? ""
    }

    static func search(_ q: String) async -> (list: [Item], errs: [String]) {
        let r = await SourceEngine.shared.lookup("return LookupSearch(q, k)", ["q": q, "k": key]) as? [String: Any]
        return ((r?["list"] as? [Item]) ?? [], (r?["errs"] as? [String]) ?? [])
    }

    static func editions(isbn: String = "", q: String = "", seed: Item? = nil) async -> (list: [Item], lang: String, sel: Int, errs: [String]) {
        var o: [String: Any] = ["isbn": isbn, "q": q]
        if let s = seed { o["seed"] = s }
        let r = await SourceEngine.shared.lookup("return LookupEditions(o, k)", ["o": o, "k": key]) as? [String: Any]
        return ((r?["list"] as? [Item]) ?? [], (r?["lang"] as? String) ?? "", NovelBridge.num(r?["sel"] ?? -1), (r?["errs"] as? [String]) ?? [])
    }

    static func covers(_ q: String) async -> (list: [Item], errs: [String]) {
        let r = await SourceEngine.shared.lookup("return LookupCovers(q, k)", ["q": q, "k": key]) as? [String: Any]
        return ((r?["list"] as? [Item]) ?? [], (r?["errs"] as? [String]) ?? [])
    }

    static func batch(_ code: String) async -> Item? {
        await SourceEngine.shared.lookup("return LookupBatch(c, k)", ["c": code, "k": key]) as? Item
    }

    static func page(_ url: String) async -> Item {
        (await SourceEngine.shared.lookup("return LookupPage(u)", ["u": url]) as? Item) ?? [:]
    }

    /// A cover from the web, ready to keep: at most 1100 points on its long side; pictures under 60 points are refused.
    static func coverImage(_ url: String, fallback: String? = nil) async -> UIImage? {
        for u in [url, fallback].compactMap({ $0 }).filter({ !$0.isEmpty }) {
            if let img = await fetchImage(u) { return img }
        }
        return nil
    }

    private static func fetchImage(_ u: String) async -> UIImage? {
        if u.hasPrefix("data:image/"), let c = u.firstIndex(of: ","), let d = Data(base64Encoded: String(u[u.index(after: c)...])) {
            return UIImage(data: d).flatMap(fit)
        }
        let r: [String: Any] = await withCheckedContinuation { c in Net.fetch(["url": u, "as": "dataurl"]) { c.resume(returning: $0) } }
        guard (r["ok"] as? Bool) == true, let s = r["dataurl"] as? String, let c = s.firstIndex(of: ","),
              let d = Data(base64Encoded: String(s[s.index(after: c)...])), let img = UIImage(data: d) else { return nil }
        return fit(img)
    }

    private static func fit(_ img: UIImage) -> UIImage? {
        let w = img.size.width * img.scale, h = img.size.height * img.scale
        guard w >= 60, h >= 60 else { return nil }
        let side = max(w, h)
        guard side > 1100 else { return img }
        let k = 1100 / side
        let size = CGSize(width: (w * k).rounded(), height: (h * k).rounded())
        let f = UIGraphicsImageRendererFormat()
        f.scale = 1
        return UIGraphicsImageRenderer(size: size, format: f).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
    }

    /// The ISBN a barcode or a typed text holds (ISBN-13 starting 978/979, else ISBN-10), digits and X otherwise.
    static func clean(_ code: String) -> String {
        let s = code.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "")
        if let r = s.range(of: #"97[89]\d{10}"#, options: .regularExpression) { return String(s[r]) }
        if let r = s.range(of: #"\b\d{9}[\dXx]\b"#, options: .regularExpression) { return String(s[r]).uppercased() }
        return s.filter { $0.isNumber || $0 == "X" || $0 == "x" }.uppercased()
    }
}
