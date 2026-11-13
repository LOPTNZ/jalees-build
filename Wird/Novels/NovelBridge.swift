import UIKit
import SwiftUI
import SafariServices

/// What the web library asks of the native novel code (bridge command "novel"), and the way back:
/// progress and reading sessions go into the book in the web app, so the library, notebook and stats see them.
@MainActor
enum NovelBridge {
    static weak var host: WebViewController?
    private static var page: NovelPageController?
    /// the open page came from the library's carousel: it faded in over the cover, and fades out as the cover flies back
    private static var pageFaded = false
    /// where the web tab bar starts, as the page last reported it (0 until it does)
    static var navTop: CGFloat = 0

    /// The height native screens over the library get: down to the tab bar.
    static func refit() {
        for d in [0.6, 1.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + d) {
                look { l in
                    guard l.navTop > 0 else { return }
                    navTop = l.navTop
                    if let v = page?.view, v.transform == .identity { v.frame.size.height = l.navTop }
                    NovelTabs.fit(l.navTop)
                }
            }
        }
    }

    static func height(_ lk: JLook, in h: UIViewController) -> CGFloat {
        let t = lk.navTop > 0 ? lk.navTop : navTop
        return t > 0 ? t : h.view.bounds.height
    }

    static func handle(_ o: [String: Any], host h: WebViewController?, reply: @escaping (Any?) -> Void) {
        if let h = h { host = h }
        let op = o["op"] as? String ?? ""
        let id = num(o["id"])
        let book = o["book"] as? String
        switch op {
        case "add":
            Task { reply(await add(o["url"] as? String ?? "")) }
        case "link":
            if let b = book { Novels.shared.link(id, book: b); sync(id) }
            reply(true)
        case "page":
            showPage(novel: id, book: book, openIndex: o["idx"].map { num($0) }, fade: (o["fade"] as? Bool) == true)
            reply(true)
        case "closePage":
            closePage(animated: false)
            reply(true)
        case "tab":
            NovelTabs.show(o["tab"] as? String ?? "")
            reply(true)
        case "cover":
            let on = (o["on"] as? Bool) == true
            page?.view.isHidden = on
            NovelTabs.cover(on)
            if !on { pageNeedsReload() }
            reply(true)
        case "firstMention":
            Task {
                let f = await Novels.shared.firstMention(id, names: (o["names"] as? [String]) ?? [])
                reply(f.map { ["n": $0.num, "sure": $0.sure] as [String: Any] })
            }
        case "toast":
            // a message from the library while a native screen covers it (an achievement, say)
            if let h = host, let t = o["text"] as? String, !t.isEmpty {
                let top = NovelBridge.top(h)
                if top !== h { Toast.show(t, in: top.view, top: 64) }
                else if (page.map { !$0.view.isHidden } ?? false) || NovelTabs.visible { Toast.show(t, in: h.view, top: 64) }
            }
            reply(true)
        case "navTop":
            navTop = CGFloat(num(o["top"]))
            if navTop > 0 {
                if let v = page?.view, v.transform == .identity { v.frame.size.height = navTop }
                NovelTabs.fit(navTop)
            }
            reply(true)
        case "read":
            openReader(novel: id, book: book, index: o["idx"].map { num($0) }, chapter: o["ch"].map { num($0) }, paragraph: o["p"].map { num($0) })
            reply(true)
        case "refresh":
            Task {
                guard let n = Novels.shared.novel(id) else { reply(["error": "ما لقيت الرواية"]); return }
                do { let f = try await Novels.shared.refresh(n); sync(id); reply(["fresh": f]) }
                catch { reply(["error": error.localizedDescription]) }
            }
        case "site":
            if let n = Novels.shared.novel(id) { openSite(n.url) }
            reply(true)
        case "epubPick":
            guard let h = host else { reply(nil); return }
            EpubStore.pick(from: top(h)) { url in
                guard let u = url else { reply(nil); return }
                reply(epubInfo(u))
            }
        case "export":
            reply(["novels": Novels.shared.exportAll()])
        case "import":
            Novels.shared.importAll((o["novels"] as? [[String: Any]]) ?? [])
            reply(true)
        default:
            reply(nil)
        }
    }

    static func num(_ v: Any?) -> Int {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s) ?? 0 }
        return 0
    }

    // MARK: adding

    private static func add(_ url: String) async -> [String: Any] {
        do {
            let r = try await Novels.shared.add(url: url) { msg in
                host?.webView.jalees("return wirdNovelProgress(t)", ["t": msg])
            }
            let n = r.novel
            var out: [String: Any] = [
                "id": n.id, "title": n.title, "author": n.author, "cover": n.cover, "url": n.url, "site": n.source,
                "total": n.total, "complete": n.complete, "translator": n.translator, "genres": n.genres
            ]
            if let i = r.openIndex { out["open"] = i }
            return out
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    // MARK: EPUB books (read in place)

    /// Adds a book from a file and says what the library needs to make its book (cover as a picture).
    static func epubInfo(_ url: URL) -> [String: Any] {
        do {
            let r = try EpubStore.add(url)
            var o: [String: Any] = ["id": r.novel.id, "title": r.novel.title, "author": r.novel.author, "site": "epub", "total": r.novel.total, "complete": true]
            if let c = r.cover, let img = UIImage(data: c), let jpg = img.jpegData(compressionQuality: 0.85) {
                o["coverData"] = "data:image/jpeg;base64," + jpg.base64EncodedString()
            }
            return o
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    /// A book opened from the Files app ("فتح في جليس" or the «جليس» folder): added in place, then shown.
    static func importEpub(_ url: URL) {
        guard let w = host?.webView else { return }
        let o = epubInfo(url)
        if let e = o["error"] as? String { if let h = host { Toast.show(e, in: h.view, top: 60) }; return }
        w.jalees("return wirdEpubAdded(o)", ["o": o])
    }

    // MARK: keeping the library in step

    /// Sends the novel's counts and place to its book in the web library.
    static func sync(_ novel: Int, opened: Bool = false) {
        var s = Novels.shared.stats(novel)
        guard let b = s["book"] as? String, !b.isEmpty else { return }
        if opened { s["opened"] = true }
        host?.webView.jalees("return wirdNovelSync(o)", ["o": s])
    }

    /// After the reader or the page closes: lets the library redraw once with everything that changed.
    static func settle() {
        host?.webView.jalees("return wirdNovelClosed()")
    }

    static func look(_ done: @escaping (JLook) -> Void) {
        guard let w = host?.webView else { done(JLook()); return }
        w.jalees("return wirdLook()") { v in done((v as? [String: Any]).map(JLook.init) ?? JLook()) }
    }

    // MARK: the novel's page (native, in Jalees's look, above the web library and below its tab bar)

    static func showPage(novel: Int, book: String?, openIndex: Int?, fade: Bool = false) {
        guard let h = host, let n = Novels.shared.novel(novel) else { return }
        closePage(animated: false, keepCover: fade)
        let bookID = book ?? n.book
        look { lk in
            let model = NovelPageModel(novel: n, book: bookID, look: lk)
            let vc = NovelPageController(model: model)
            model.close = { closePage(animated: true) }
            page = vc
            h.addChild(vc)
            vc.view.frame = CGRect(x: 0, y: 0, width: h.view.bounds.width, height: height(lk, in: h))
            vc.view.autoresizingMask = [.flexibleWidth]
            h.view.addSubview(vc.view)
            vc.didMove(toParent: h)
            pageFaded = fade
            refit()
            if fade {
                // from the carousel: the cover is flying up in the library underneath; the page appears as it lands
                vc.view.alpha = 0
                UIView.animate(withDuration: 0.28, delay: 0.3, options: [.curveEaseOut, .allowUserInteraction]) { vc.view.alpha = 1 }
            } else {
                // like a page pushed in a right-to-left app: it comes in from the left
                vc.view.transform = CGAffineTransform(translationX: -h.view.bounds.width, y: 0)
                UIView.animate(withDuration: 0.34, delay: 0, usingSpringWithDamping: 0.92, initialSpringVelocity: 0, options: [.allowUserInteraction]) {
                    vc.view.transform = .identity
                }
            }
            if let i = openIndex { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { openReader(novel: novel, book: bookID, index: i, chapter: nil, paragraph: nil) } }
        }
    }

    static func closePage(animated: Bool, keepCover: Bool = false) {
        guard let vc = page else { return }
        page = nil
        let faded = pageFaded
        pageFaded = false
        if !keepCover { host?.webView.jalees("return wirdNovelPageGone(a)", ["a": animated && faded]) }
        let done = {
            vc.willMove(toParent: nil)
            vc.view.removeFromSuperview()
            vc.removeFromParent()
            settle()
        }
        guard animated, let w = vc.view.superview?.bounds.width else { done(); return }
        if faded && vc.view.transform == .identity {
            UIView.animate(withDuration: 0.24, delay: 0, options: [.curveEaseIn], animations: { vc.view.alpha = 0 }, completion: { _ in done() })
            return
        }
        UIView.animate(withDuration: 0.26, delay: 0, options: [.curveEaseIn], animations: {
            vc.view.transform = CGAffineTransform(translationX: -w, y: 0)
        }, completion: { _ in done() })
    }

    static func pageNeedsReload() { page?.model.reload() }

    /// Back to Jalees's own tabs with nothing native over the library (a widget opened a book, say).
    static func toLibrary() {
        closePage(animated: false)
        NovelTabs.hide()
        host?.webView.jalees("return wirdNavMain()")
    }

    /// for the simulator pictures: the open page's «تعديل»
    static func debugEdit() { page?.model.edit() }

    // MARK: reading

    /// Opens the reader: at `index`, or at a saved chapter and paragraph (a highlight), or where the reader left off.
    static func openReader(novel: Int, book: String?, index: Int?, chapter: Int?, paragraph: Int?) {
        guard let h = host, let n = Novels.shared.novel(novel) else { return }
        let chapters = Novels.shared.chapters(novel)
        guard !chapters.isEmpty else { return }
        var at = 0
        var place: (p: Int, o: Double)?
        if let i = index {
            at = i
        } else if let c = chapter, let i = chapters.firstIndex(where: { $0.id == c }) {
            at = i
            place = paragraph.map { (p: $0, o: 0) }
        } else if n.curChapter != 0, let i = chapters.firstIndex(where: { $0.id == n.curChapter }) {
            at = i
            place = (p: n.curP, o: n.curO)
        } else if let i = chapters.firstIndex(where: { !$0.read }) {
            at = i
        }
        let reader = ReaderViewController(novel: n, chapters: chapters, index: at, place: place)
        reader.bookID = (book?.isEmpty == false ? book : nil) ?? (n.book.isEmpty ? nil : n.book)
        reader.onClose = {
            Novels.shared.reload()
            sync(novel, opened: true)
            settle()
            pageNeedsReload()
        }
        top(h).present(reader, animated: true)
        sync(novel, opened: true)
    }

    // MARK: the site, inside Jalees

    static func openSite(_ address: String) {
        guard let h = host, let u = URL(string: address), u.scheme?.hasPrefix("http") == true else { return }
        let sf = SFSafariViewController(url: u)
        sf.preferredControlTintColor = .label
        sf.dismissButtonStyle = .close
        top(h).present(sf, animated: true)
    }

    static func top(_ from: UIViewController) -> UIViewController {
        var v = from
        while let p = v.presentedViewController { v = p }
        return v
    }
}

/// Holds the novel page; a swipe from the right edge goes back, as in a right-to-left app.
final class NovelPageController: UIHostingController<NovelPageView> {
    let model: NovelPageModel

    init(model: NovelPageModel) {
        self.model = model
        super.init(rootView: NovelPageView(model: model))
        view.backgroundColor = model.look.bg
        let edge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(swiped(_:)))
        edge.edges = .right
        view.addGestureRecognizer(edge)
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("no storyboard") }

    @objc private func swiped(_ g: UIScreenEdgePanGestureRecognizer) {
        let x = g.translation(in: view.superview).x
        switch g.state {
        case .changed:
            view.transform = CGAffineTransform(translationX: min(0, x), y: 0)
        case .ended, .cancelled:
            if x < -90 || g.velocity(in: view.superview).x < -600 {
                Task { @MainActor in NovelBridge.closePage(animated: true) }
            } else {
                UIView.animate(withDuration: 0.2) { self.view.transform = .identity }
            }
        default:
            break
        }
    }
}

/// Downloads chapters one after another, quietly, so they can be read without a connection.
@MainActor
final class Downloads: ObservableObject {
    static let shared = Downloads()

    @Published private(set) var waiting: [Int] = []
    @Published private(set) var done = 0
    @Published private(set) var failed = 0
    private var running = false

    var active: Bool { !waiting.isEmpty }

    func add(_ ids: [Int], source: String) {
        let fresh = ids.filter { !waiting.contains($0) }
        guard !fresh.isEmpty else { return }
        if waiting.isEmpty { done = 0; failed = 0 }
        waiting.append(contentsOf: fresh)
        guard !running else { return }
        running = true
        Task { await run(source: source) }
    }

    func cancel() { waiting.removeAll() }

    private func run(source: String) async {
        while let id = waiting.first {
            if let ch = Novels.shared.chapter(id), !ch.saved {
                do {
                    _ = try await Novels.shared.text(ch, source: source)
                    done += 1
                    if source == "kolnovel" && ReaderSettings.shared.prefs.comments {
                        await Comments.keepAll(chapterURL: ch.url, chapter: ch.id, novel: ch.novel)
                    }
                } catch { failed += 1 }
                try? await Task.sleep(nanoseconds: 350_000_000)
            } else {
                done += 1
            }
            if !waiting.isEmpty { waiting.removeFirst() }
            if done % 10 == 0 { NovelBridge.pageNeedsReload() }
        }
        running = false
        NovelBridge.pageNeedsReload()
    }
}
