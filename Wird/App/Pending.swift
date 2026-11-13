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
    static func addBook() { later("إضافة كتاب") }
    static func editBook(_ id: String) { later("تعديل الكتاب") }
    static func scanAdd() { later("الباركود") }
    static func scanBatch() { later("المسح المتتابع") }
    static func multiAdd() { later("عدة كتب") }
    static func importBackup() { later("الاستعادة") }
    static func startRead(_ id: String) { later("الجلسة") }
    static func finish(_ id: String, volume: String?) {}
    static func note(_ id: String, kind: String) { later("الدفتر") }
    static func bookCard(_ id: String) { later("بطاقة الكتاب") }
    static func pdf(_ id: String) { later("ملخص PDF") }
    static func shelfStyle() { later("شكل الرف") }
}
