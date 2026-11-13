import Foundation
import Combine

// Parts whose full versions come in later phases of the port (docs/plan/swift/plan.md). Each is called from where it
// will be needed, so filling it in later changes nothing around it. Nothing here may remain at delivery.

/// Achievements (phase 6: إنجازاتي): checks for new ones after a change.
@MainActor
enum Achievements {
    static func check() {}
}

/// The widgets' data in the App Group (phase 8).
@MainActor
enum WidgetFeed {
    static func update() {}
}

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
    private static func later(_ what: String) { ToastCenter.shared.show(what + " · قيد البناء") }
    static func addBook() { Present.shared.open(.bookForm(nil)) }
    static func editBook(_ id: String) { Present.shared.open(.bookForm(id)) }
    static func scanAdd() { Scanning.single() }
    static func scanBatch() { Scanning.batch() }
    static func multiAdd() { Present.shared.open(.multiAdd) }
    static func importBackup() { later("الاستعادة") }
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
    static func bookCard(_ id: String) { later("بطاقة الكتاب") }
    static func pdf(_ id: String) { later("ملخص PDF") }
}
