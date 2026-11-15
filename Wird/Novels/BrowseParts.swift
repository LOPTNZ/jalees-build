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

    func load(_ home: String) async -> UIImage? {
        guard let u = URL(string: home), let host = u.host, let scheme = u.scheme else { return nil }
        if let i = cached(host) { return i }
        guard !asking.contains(host) else { return nil }
        asking.insert(host)
        defer { asking.remove(host) }
        let base = scheme + "://" + host
        var tries = [base + "/apple-touch-icon.png", base + "/apple-touch-icon-precomposed.png"]
        // the home page names its icon
        if let html = try? await Fetcher.html(home) {
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
        tries.append(base + "/favicon.ico")
        for t in tries {
            guard let url = URL(string: t) else { continue }
            var r = URLRequest(url: url, timeoutInterval: 12)
            r.setValue(Fetcher.ua, forHTTPHeaderField: "User-Agent")
            guard let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200,
                  let img = UIImage(data: d), img.size.width >= 16 else { continue }
            let out = img.size.width > 180 ? UIGraphicsImageRenderer(size: CGSize(width: 180, height: 180)).image { _ in img.draw(in: CGRect(x: 0, y: 0, width: 180, height: 180)) } : img
            memory[host] = out
            if let png = out.pngData() { try? png.write(to: folder.appendingPathComponent(host + ".png")) }
            return out
        }
        return nil
    }
}

struct SiteIcon: View {
    let home: String
    let name: String
    let look: JLook
    var size: CGFloat = 44
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
            if let h = URL(string: home)?.host, let i = SiteIcons.shared.cached(h) { img = i; return }
            img = await SiteIcons.shared.load(home)
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
}
