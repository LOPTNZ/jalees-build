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
