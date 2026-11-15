import Foundation
import Combine

// Parts whose full versions come in later phases of the port (docs/plan/swift/plan.md). Each is called from where it
// will be needed, so filling it in later changes nothing around it. Nothing here may remain at delivery.

/// Where the notebook should open (phase 5: دفتري).
@MainActor
final class NotebookNav: ObservableObject {
    static let shared = NotebookNav()
    @Published var book: String?
    @Published var kind: String?
    @Published var character: String?

    func show(book: String?, kind: String?, character: String? = nil) {
        self.book = book
        self.kind = kind
        self.character = character
    }
}

/// Screens of later phases that the library already opens: book form and adding (3), sessions and finishing (4),
/// notebook entries (5), the book card and PDF (7).
@MainActor
enum Flows {
    static func addBook() { Present.shared.open(.bookForm(nil)) }
    static func editBook(_ id: String) { Present.shared.open(.bookForm(id)) }
    static func scanAdd() { Scanning.single() }
    static func scanBatch() { Scanning.batch() }
    static func multiAdd() { Present.shared.open(.multiAdd) }
    static func importBackup() { BackupImport.shared.picking = true }
    static func startRead(_ id: String) { SessionModel.shared.start(id) }
    /// the finishing card after a book or a volume ends
    static func finish(_ id: String, volume: String?) { Present.shared.open(.finish(id, volume, true)) }
    /// the review of a book or a volume, from its page
    static func review(_ id: String, volume: String?) { Present.shared.open(.finish(id, volume, false)) }
    /// a notebook entry: a new one of a kind, «edit:<kind>:<id>», or «review» (the book's words)
    static func note(_ id: String, kind: String) {
        if kind == "review" { Present.shared.open(.review(id)); return }
        let p = kind.split(separator: ":").map(String.init)
        if p.count == 3 && p[0] == "edit" {
            if p[1] == "char" { Present.shared.open(.character(id, p[2])) } else { Present.shared.open(.item(ItemRef(book: id, kind: p[1], item: p[2]))) }
            return
        }
        Present.shared.open(.item(ItemRef(book: id, kind: kind, item: nil)))
    }
    static func bookCard(_ id: String) { Present.shared.open(.card(CardRequest(kind: .book, book: id))) }
    static func quoteCard(_ id: String, quote: String) { Present.shared.open(.card(CardRequest(kind: .quote, book: id, quote: quote))) }
    static func pdf(_ id: String) { Present.shared.open(.pdf(id)) }

    /// A book's (or a novel's) status, from its page. Finishing opens the finish sheet (rating, review); a change that
    /// clears where you were or your rating can be taken back from its toast.
    static func setStatus(_ id: String, _ v: String) {
        let lib = Library.shared
        guard let s = BookStatus(rawValue: v), let b = lib.state.book(id), b.status != s else { return }
        let prev = b.status
        let before = b.raw
        // a novel's place is its chapters read (NovelLibrary keeps it), not set by its status
        let isNovel = b.novel != nil
        Haptics.play("sel")
        lib.changeBook(id) { x in
            x.status = s
            if s == .done {
                if !isNovel {
                    x.vi = max(0, x.volumes.count - 1)
                    if let t = x.volumes.last?.total { x.pos = t }
                }
                x.finish = Millis.now
                if x.start == nil { x.start = Millis.now }
            } else {
                x.finish = nil
            }
            if (s == .reading || s == .paused || s == .dnf) && x.start == nil { x.start = Millis.now }
            if s == .want && !isNovel { x.pos = 0; x.vi = 0 }
            if s != .done && s != .dnf { x.rating = 0 }
        }
        Achievements.check()
        if s == .done && prev != .done { finish(id, volume: nil); return }
        let lostPlace = !isNovel && s == .want && (b.pos > 0 || b.vi > 0)
        let lostRating = b.rating > 0 && s != .done && s != .dnf
        if lostPlace || lostRating {
            ToastCenter.shared.show(lostPlace ? "رجع «أريد قراءته» وانمسح مكانك" : "انمسح تقييمك مع تغيير الحالة") {
                Library.shared.changeBook(id) { $0 = Book(Library.fixBook(before)) }
            }
        }
    }
}
