import UIKit

/// Screens for pictures and checks on the simulator. Launch with `-JaleesRoute <route>`:
/// `page` (the built-in sample novel's page), `reader`, `reader-chrome`, `reader-themes`, `reader-custom`,
/// `reader-contents`, `reader-end`, and `live <series url> <chapter number>` (adds a real novel and opens that chapter).
@MainActor
enum DebugRoute {
    static func run(_ root: WebViewController) {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-JaleesRoute"), i + 1 < args.count else { return }
        let route = args[i + 1]
        NovelBridge.host = root
        Task { @MainActor in
            await waitForLibrary()
            if route == "live", i + 2 < args.count {
                do {
                    let r = try await Novels.shared.add(url: args[i + 2]) { s in NSLog("jalees live: %@", s) }
                    let book = await ensureBook(r.novel)
                    let chs = Novels.shared.chapters(r.novel.id)
                    let want = i + 3 < args.count ? args[i + 3] : "1"
                    let at = chs.firstIndex { $0.num == want } ?? 0
                    NSLog("jalees live: added %@ with %d chapters, opening index %d", r.novel.title, chs.count, at)
                    NovelBridge.openReader(novel: r.novel.id, book: book, index: at, chapter: nil, paragraph: nil)
                } catch {
                    NSLog("jalees live: failed %@", error.localizedDescription)
                }
                return
            }
            if route.hasPrefix("epub") {
                // the simulator check copies tools/sim/sample.epub into the app's Documents folder
                let f = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("sample.epub")
                NSLog("jalees epub: file exists %@", FileManager.default.fileExists(atPath: f.path) ? "yes" : "no")
                NovelBridge.importEpub(f)
                if route == "epub-read" {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    if let n = Novels.shared.list.first(where: { $0.source == "epub" }) {
                        NovelBridge.closePage(animated: false)
                        NovelBridge.openReader(novel: n.id, book: n.book, index: 0, chapter: nil, paragraph: nil)
                    }
                }
                return
            }
            // every check starts from the default way of reading
            if !route.contains("paged") && !route.contains("curl") { ReaderSettings.shared.prefs.mode = route.contains("swipe") ? "continuous" : "chapter" }
            guard let sample = Sample.ensure() else { return }
            let book = await ensureBook(sample)
            if route == "car" {
                // the library carousel opening a novel: its native page, not the web one
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                root.webView.jalees("return wirdDebugCar()")
            } else if route.hasPrefix("tab-") {
                let t = String(route.dropFirst(4))
                if t == "history" { for c in Novels.shared.chapters(sample.id).prefix(3) { Novels.shared.logHistory(novel: sample.id, chapter: c.id) } }
                if t == "updates" {
                    let ids = Novels.shared.chapters(sample.id).suffix(3).map(\.id)
                    for (k, id) in ids.enumerated() { DB.shared.run("UPDATE chapters SET found=? WHERE id=?", [Date().timeIntervalSince1970 - Double(k * 90_000), id]) }
                    DB.shared.set("updates.checked", String(Date().timeIntervalSince1970))
                }
                root.webView.jalees("return wirdDebugTab('browse')")
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                if t == "site" { NovelTabs.show("site") } else if t != "browse" { root.webView.jalees("return wirdDebugTab(t)", ["t": t]) }
            } else if route == "edit" {
                // editing a novel found while browsing: the library's form shows in full, above the novels' screens
                root.webView.jalees("return wirdDebugTab('browse')")
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                NovelBridge.showPage(novel: sample.id, book: book, openIndex: nil)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                NovelBridge.debugEdit()
            } else if route == "page" {
                NovelBridge.showPage(novel: sample.id, book: book, openIndex: nil)
            } else if route.hasPrefix("reader") {
                NovelBridge.openReader(novel: sample.id, book: book, index: 2, chapter: nil, paragraph: nil)
                let parts = route.split(separator: "-")
                if parts.count > 1, let reader = NovelBridge.top(root) as? ReaderViewController {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    reader.debug(String(parts[1]))
                }
            }
        }
    }

    /// The library page must have run its scripts before the novel code can talk to it.
    static func waitForLibrary() async {
        for _ in 0..<60 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let w = NovelBridge.host?.webView else { continue }
            let ready: Bool = await withCheckedContinuation { c in
                w.jalees("return typeof wirdNovelEnsureBook === 'function'") { v in c.resume(returning: (v as? Bool) ?? false) }
            }
            if ready { return }
        }
    }

    /// Makes (or finds) the library book for a novel, the same way adding one from the library does.
    static func ensureBook(_ n: Novel) async -> String {
        if !n.book.isEmpty { return n.book }
        let o: [String: Any] = ["id": n.id, "title": n.title, "author": n.author, "url": n.url, "site": n.source,
                                "total": n.total, "complete": n.complete, "translator": n.translator, "genres": n.genres]
        guard let w = NovelBridge.host?.webView else { return "" }
        let id: String = await withCheckedContinuation { c in
            w.jalees("return wirdNovelEnsureBook(o)", ["o": o]) { v in c.resume(returning: (v as? String) ?? "") }
        }
        if !id.isEmpty { Novels.shared.link(n.id, book: id) }
        return id
    }
}
