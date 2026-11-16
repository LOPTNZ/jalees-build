import UIKit
import SwiftUI
import SafariServices

/// The novel code's doors to the rest of the app: adding a novel or a book file, keeping its library book in step,
/// showing a novel's page, the reader and the site.
@MainActor
enum NovelBridge {
    /// the app's root screen: the reader and the site are presented from it
    static weak var host: UIViewController?

    static func num(_ v: Any?) -> Int {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s) ?? 0 }
        if let n = v as? NSNumber { return n.intValue }
        return 0
    }

    // MARK: adding

    /// Adds a novel from its link (or finds it), makes its library book, and says what was added.
    static func add(_ url: String, progress: @escaping (String) -> Void) async -> [String: Any] {
        do {
            let r = try await Novels.shared.add(url: url, progress: progress)
            let n = r.novel
            var out: [String: Any] = [
                "id": n.id, "title": n.title, "author": n.author, "cover": n.cover, "url": n.url, "site": n.source,
                "total": n.total, "complete": n.complete, "translator": n.translator, "genres": n.genres
            ]
            out["book"] = await NovelLibrary.adopt(out)
            if let i = r.openIndex { out["open"] = i }
            return out
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    /// A novel found while browsing: its page, to look at. It joins the library with «أضف لمكتبتك» or its first
    /// read (adopt), not by being looked at.
    static func open(_ url: String, progress: @escaping (String) -> Void) async throws {
        let r = try await Novels.shared.add(url: url, progress: progress)
        let book = r.novel.book
        let inLibrary = !book.isEmpty && Library.shared.state.book(book) != nil
        BookLayer.shared.openNovel(r.novel.id, book: inLibrary ? book : "")
    }

    /// A novel being looked at joins the library: its book (with its cover from the site). Returns the book's id.
    static func adopt(novel id: Int) async -> String {
        guard let n = Novels.shared.novel(id) else { return "" }
        let o: [String: Any] = ["id": n.id, "title": n.title, "author": n.author, "cover": n.cover, "url": n.url, "site": n.source,
                                "total": n.total, "complete": n.complete, "translator": n.translator, "genres": n.genres]
        let book = await NovelLibrary.adopt(o)
        Novels.shared.reload()
        return book
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
        NovelLibrary.epubAdded(epubInfo(url))
    }

    // MARK: keeping the library in step

    /// The novel's counts and place, onto its book in the library.
    static func sync(_ novel: Int, opened: Bool = false) {
        var s = Novels.shared.stats(novel)
        guard let b = s["book"] as? String, !b.isEmpty else { return }
        if opened { s["opened"] = true }
        NovelLibrary.sync(s)
    }

    static func look(_ done: @escaping (JLook) -> Void) { done(Appearance.shared.look) }

    // MARK: the novel's page (a page in the open tab)

    static func showPage(novel: Int, book: String?, openIndex: Int?) {
        guard let n = Novels.shared.novel(novel) else { return }
        let bookID = book ?? n.book
        Router.shared.openNovel(novel, book: bookID)
        if let i = openIndex { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { openReader(novel: novel, book: bookID, index: i, chapter: nil, paragraph: nil) } }
    }

    /// The open novel page reads its book again (after the reader, a download, a change).
    static func pageNeedsReload() { NotificationCenter.default.post(name: .novelPageReload, object: nil) }

    /// Back to Jalees's own tabs, at the library.
    static func toLibrary() { Router.shared.select(.library) }

    // MARK: reading

    /// Opens the reader: at `index`, or at a saved chapter and paragraph (a highlight), or where the reader left off.
    static func openReader(novel: Int, book: String?, index: Int?, chapter: Int?, paragraph: Int?) {
        guard let h = host, let n = Novels.shared.novel(novel) else { return }
        let chapters = Novels.shared.chapters(novel)
        guard !chapters.isEmpty else { Toaster.show("ما فيه فصول تنقرأ في هذا الكتاب"); return }
        var at = 0
        var place: (p: Int, o: Double)?
        if let i = index {
            // `index` is the chapter's idx; its place in the list differs when idx has gaps
            at = chapters.firstIndex(where: { $0.idx == i }) ?? min(max(0, i), chapters.count - 1)
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
            pageNeedsReload()
        }
        // a sheet that is closing (the quote's form after «اذهب لمكانها») would take the reader away with it: the
        // reader waits for it to be gone, and never sits on one that is leaving
        Present.whenClear { top(h).present(reader, animated: true) }
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

    /// A link from outside (a widget, a share from Safari): the reader closes (its place and session saved) and any
    /// sheet closes, then `then` runs on a clear screen. Nothing open: it runs straight away.
    static func clearScreen(_ then: @escaping () -> Void) {
        guard let h = host, h.presentedViewController != nil else { then(); return }
        var v = h.presentedViewController
        while let x = v {
            if let r = x as? ReaderViewController, !r.isBeingDismissed { r.closeTapped(); break }
            v = x.presentedViewController
        }
        Present.shared.modal = nil
        if h.presentedViewController != nil, !(h.presentedViewController?.isBeingDismissed ?? false) { h.dismiss(animated: true) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { then() }
    }

    static func top(_ from: UIViewController) -> UIViewController {
        var v = from
        while let p = v.presentedViewController, !p.isBeingDismissed { v = p }
        return v
    }
}

extension Notification.Name {
    static let novelPageReload = Notification.Name("jalees.novelPageReload")
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
        var lastReload = 0
        while let id = waiting.first {
            if let ch = Novels.shared.chapter(id), !ch.saved {
                // each chapter's own novel decides the site (the queue can hold chapters of several novels)
                let source = Novels.shared.novel(ch.novel)?.source ?? source
                do {
                    _ = try await Novels.shared.text(ch, source: source)
                    done += 1
                    if source == "kolnovel" && ReaderSettings.shared.prefs.comments {
                        await Comments.keepAll(chapterURL: ch.url, chapter: ch.id, novel: ch.novel)
                    }
                } catch NovelError.blocked {
                    // the site wants its check and it was not passed: the whole run stops, with one message
                    waiting.removeAll()
                    Toaster.show("الموقع طلب تحقق ما انحل، وقفت التحميل. افتح فصل من الموقع وحلّ التحقق، وبعدها حمّل مرة ثانية.")
                    break
                } catch { failed += 1 }
                try? await Task.sleep(nanoseconds: 350_000_000)
            } else {
                done += 1
            }
            // cancel() may have emptied the queue (or add() refilled it) while this chapter loaded: only remove this one
            if waiting.first == id { waiting.removeFirst() }
            // the page reloads on real progress only, every ten chapters
            if done >= lastReload + 10 { lastReload = done; NovelBridge.pageNeedsReload() }
        }
        running = false
        NovelBridge.pageNeedsReload()
    }
}

/// Links shared from Safari (WirdShare): each becomes a novel, added and opened, as with + ← «رواية من موقع».
@MainActor
enum SharedAdd {
    private static var busy = false

    static func process(_ extra: String? = nil) {
        var links = SharedLinks.take()
        if let e = extra, !e.isEmpty, !links.contains(e) { links.append(e) }
        guard !links.isEmpty, !busy else { return }
        busy = true
        Task { @MainActor in
            for l in links {
                Toaster.show("أضيف الرواية من الرابط…")
                let r = await NovelBridge.add(l) { _ in }
                if let e = r["error"] as? String { Toaster.show(e); continue }
                let book = (r["book"] as? String) ?? ""
                let id = NovelBridge.num(r["id"])
                NovelBridge.clearScreen {
                    NovelBridge.showPage(novel: id, book: book, openIndex: r["open"].map { NovelBridge.num($0) })
                }
                Toaster.show("انضافت «\((r["title"] as? String) ?? "")»")
            }
            busy = false
        }
    }
}
