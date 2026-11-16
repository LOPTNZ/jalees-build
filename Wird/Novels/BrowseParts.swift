import SwiftUI
import UIKit
#if canImport(Translation)
import Translation
#endif

// The pieces of تصفّح: a site's own icon, and an Arabic search said in English for the English sites.

/// A site's icon, from the site itself (its apple-touch-icon, else its favicon), kept on the phone.
@MainActor
final class SiteIcons {
    static let shared = SiteIcons()
    private var memory: [String: UIImage] = [:]
    private var asking: Set<String> = []

    private var folder: URL {
        let u = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("siteicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func cached(_ host: String) -> UIImage? {
        if let i = memory[host] { return i }
        if let d = try? Data(contentsOf: folder.appendingPathComponent(host + ".png")), let i = UIImage(data: d) {
            memory[host] = i
            return i
        }
        return nil
    }

    /// `logo`: the site's whole logo (its home page's og:image) comes first: some sites' own icon is a bad crop of it
    /// (ملوك الروايات's cut its crown and wings off at an angle, and looked tilted).
    func load(_ home: String, logo: Bool = false) async -> UIImage? {
        guard let u = URL(string: home), let h = u.host, let scheme = u.scheme else { return nil }
        let host = logo ? h + ".logo" : h
        if let i = cached(host) { return i }
        guard !asking.contains(host) else { return nil }
        asking.insert(host)
        defer { asking.remove(host) }
        let base = scheme + "://" + h
        var tries = [base + "/apple-touch-icon.png", base + "/apple-touch-icon-precomposed.png"]
        // the home page names its icon. A plain request: a site that answers with its robot check is skipped (the
        // app's own fetcher would ask the owner to pass the check, just for an icon)
        if let html = await Self.quietHTML(u) {
            for re in [#"<link[^>]+rel=["'][^"']*apple-touch-icon[^"']*["'][^>]*href=["']([^"']+)"#,
                       #"<link[^>]+rel=["'][^"']*icon[^"']*["'][^>]*href=["']([^"']+)"#,
                       #"<link[^>]+href=["']([^"']+)["'][^>]*rel=["'][^"']*icon"#] {
                if let r = html.range(of: re, options: [.regularExpression, .caseInsensitive]) {
                    let tag = String(html[r])
                    if let h = tag.range(of: #"href=["']([^"']+)"#, options: .regularExpression) {
                        let raw = tag[h].dropFirst(6)
                        if let abs = URL(string: String(raw), relativeTo: u)?.absoluteString { tries.insert(abs, at: tries.count > 1 ? 1 : 0) }
                    }
                }
            }
        }
        if logo, let html = await Self.quietHTML(u),
           let r = html.range(of: #"<meta[^>]+property=["']og:image["'][^>]*content=["']([^"']+)"#, options: [.regularExpression, .caseInsensitive]),
           let c = html[r].range(of: #"content=["']([^"']+)"#, options: .regularExpression),
           let abs = URL(string: String(html[r][c].dropFirst(9)), relativeTo: u)?.absoluteString {
            tries.insert(abs, at: 0)
        }
        tries.append(base + "/favicon.ico")
        for t in tries {
            guard let url = URL(string: t) else { continue }
            var r = URLRequest(url: url, timeoutInterval: 12)
            r.setValue(Fetcher.ua, forHTTPHeaderField: "User-Agent")
            // no AVIF asked for: its decoder is slow and once stalled the whole app (same as RemoteImages)
            r.setValue("image/webp,image/jpeg,image/png,*/*;q=0.5", forHTTPHeaderField: "Accept")
            guard let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200 else { continue }
            // decoded and made small on the decode queue, not on the main thread
            guard let out = await Library.decoded(d, max: 180), out.size.width >= 16 else { continue }
            memory[host] = out
            let file = folder.appendingPathComponent(host + ".png")
            Task.detached(priority: .utility) { if let png = out.pngData() { try? png.write(to: file) } }
            return out
        }
        return nil
    }
}

extension SiteIcons {
    nonisolated static func quietHTML(_ u: URL) async -> String? {
        var r = URLRequest(url: u, timeoutInterval: 12)
        r.setValue(Fetcher.ua, forHTTPHeaderField: "User-Agent")
        guard let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let html = String(decoding: d.prefix(200_000), as: UTF8.self)
        return html.lowercased().contains("challenge-platform") ? nil : html
    }
}

struct SiteIcon: View {
    let home: String
    let name: String
    let look: JLook
    var size: CGFloat = 44
    /// the site's whole logo rather than its icon (a site definition's `icon: 'og'`)
    var logo = false
    @State private var img: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).fill(Color(look.surface2))
            if let i = img {
                Image(uiImage: i).resizable().interpolation(.high).scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            } else {
                // until (or unless) the site gives its icon: its first letter
                Text(String(name.trimmingCharacters(in: .whitespaces).prefix(1))).font(JFont.display(size * 0.45, .bold))
                    .foregroundStyle(Color(look.primary))
            }
        }
        .frame(width: size, height: size)
        .task(id: home) {
            if let h = URL(string: home)?.host, let i = SiteIcons.shared.cached(logo ? h + ".logo" : h) { img = i; return }
            img = await SiteIcons.shared.load(home, logo: logo)
        }
    }
}

/// An Arabic search sent to the English sites in English: translated on the phone by Apple's translation (iOS 18
/// and later; the phone may ask once to download Arabic). Without it the English sites get the words as typed.
struct EnglishQuery: ViewModifier {
    @Binding var request: String?
    let done: (String?) -> Void

    func body(content: Content) -> some View {
        #if canImport(Translation)
        if #available(iOS 18.0, *) {
            content.modifier(EnglishQuery18(request: $request, done: done))
        } else {
            content.onChange(of: request) { r in if r != nil { request = nil; done(nil) } }
        }
        #else
        content.onChange(of: request) { r in if r != nil { request = nil; done(nil) } }
        #endif
    }
}

#if canImport(Translation)
@available(iOS 18.0, *)
private struct EnglishQuery18: ViewModifier {
    @Binding var request: String?
    let done: (String?) -> Void
    @State private var config: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .onChange(of: request) { r in
                guard r != nil else { return }
                if config == nil {
                    config = TranslationSession.Configuration(source: Locale.Language(identifier: "ar"), target: Locale.Language(identifier: "en"))
                } else {
                    config?.invalidate()
                }
            }
            .translationTask(config) { session in
                guard let r = request else { return }
                let out = try? await session.translate(r)
                await MainActor.run {
                    request = nil
                    done(out?.targetText)
                }
            }
    }
}
#endif

enum SearchWords {
    private static let small: Set<String> = ["of", "the", "a", "an", "in", "on", "to", "and", "for", "at", "with"]

    /// Other orders of an English title's words, for a site that matches its words in order: «embers of the deep
    /// sea» → «deep sea embers», «sea embers deep»… (at most four).
    static func rotations(_ q: String) -> [String] {
        let words = q.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { !small.contains($0) }
        guard words.count >= 2, words.allSatisfy({ $0.unicodeScalars.allSatisfy { $0.isASCII } }) else { return [] }
        var out: [String] = []
        for i in 1..<words.count {
            out.append((Array(words[i...]) + Array(words[..<i])).joined(separator: " "))
        }
        let joined = words.joined(separator: " ")
        if joined != q.lowercased() { out.insert(joined, at: 0) }
        return Array(out.prefix(4))
    }

    static func hasArabic(_ s: String) -> Bool { s.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) } }

    /// A name as search compares it: Words.norm (no marks, one hamza form), and every mark of punctuation a space.
    static func fold(_ s: String) -> String {
        Words.norm(s).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }

    /// Search results with the closest names first: the name itself, then names starting with it, holding it, holding
    /// all its words (in any order); otherwise the site's own order stays.
    static func ranked(_ items: [[String: Any]], for q: String) -> [[String: Any]] {
        let want = fold(q)
        guard !want.isEmpty else { return items }
        let words = want.split(separator: " ").map(String.init)
        func score(_ it: [String: Any]) -> Int {
            let t = fold(it["title"] as? String ?? "")
            if t == want { return 0 }
            if t.hasPrefix(want) { return 1 }
            if t.contains(want) { return 2 }
            let tw = Set(t.split(separator: " ").map(String.init))
            if words.allSatisfy({ tw.contains($0) }) { return 3 }
            return 4
        }
        return items.enumerated()
            .sorted { a, b in
                let (x, y) = (score(a.element), score(b.element))
                return x != y ? x < y : a.offset < b.offset
            }
            .map(\.element)
    }
}

/// A picture from a site (a novel's cover while browsing): kept in memory, fetched with the browser's name and the
/// site as referrer, and tried again once. SwiftUI's AsyncImage left covers blank for good when a scroll cancelled
/// their loading.
@MainActor
final class RemoteImages {
    static let shared = RemoteImages()
    private let cache = NSCache<NSString, UIImage>()
    private var running: [String: Task<UIImage?, Never>] = [:]

    /// by size, not count: three hundred covers held about 130 MB while a long list was browsed
    init() { cache.totalCostLimit = 48 * 1024 * 1024 }

    func cached(_ url: String) -> UIImage? { cache.object(forKey: url as NSString) }

    /// A site's picture as the site's own pages get it: the browser's name, the site as referrer, a second try.
    /// (Plain requests were refused by some image hosts, and a novel added to the library got no cover.)
    nonisolated static func data(_ url: String) async -> Data? {
        guard let u = URL(string: url) else { return nil }
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 700_000_000) }
            var r = URLRequest(url: u, timeoutInterval: 20)
            r.setValue(Fetcher.ua, forHTTPHeaderField: "User-Agent")
            // no AVIF: image servers that are offered it send it, and its decoder (no hardware for it before the
            // iPhone 15 Pro) is slow and once held the whole app (Library.decodeQueue)
            r.setValue("image/webp,image/jpeg,image/png,*/*;q=0.5", forHTTPHeaderField: "Accept")
            if let host = u.host { r.setValue("https://" + host.split(separator: ".").suffix(2).joined(separator: ".") + "/", forHTTPHeaderField: "Referer") }
            guard let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200, !d.isEmpty else { continue }
            return d
        }
        return nil
    }

    func load(_ url: String) async -> UIImage? {
        if let i = cached(url) { return i }
        if let t = running[url] { return await t.value }
        let t = Task<UIImage?, Never> { [cache] in
            guard let d = await RemoteImages.data(url) else { return nil }
            // decoded small, off the screen's thread and off the shared pool (Library.decodeQueue)
            let img: UIImage? = await Library.decoded(d, max: 400)
            if let i = img { cache.setObject(i, forKey: url as NSString, cost: Int(i.size.width * i.size.height * i.scale * i.scale * 4)) }
            return img
        }
        running[url] = t
        let out = await t.value
        running[url] = nil
        return out
    }
}

/// The picture is kept with its address: a view that is handed another address (a list that changed under it) never
/// shows the old picture for the new one.
struct RemoteImage<P: View>: View {
    let url: String
    @ViewBuilder var placeholder: () -> P
    @State private var got: (url: String, image: UIImage)?

    var body: some View {
        Group {
            if let i = RemoteImages.shared.cached(url) ?? (got?.url == url ? got?.image : nil) {
                Image(uiImage: i).resizable().scaledToFill()
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard !url.isEmpty, RemoteImages.shared.cached(url) == nil else { return }
            let want = url
            if let i = await RemoteImages.shared.load(want), want == url { got = (want, i) }
        }
    }
}
