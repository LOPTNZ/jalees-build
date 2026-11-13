import SwiftUI
import UIKit

/// Where the app is: which tab group is open, the tab open in each group, and each tab's own stack of pages,
/// so every tab keeps its place, like iPhone tabs do.
@MainActor
final class Router: ObservableObject {
    static let shared = Router()

    enum Group: String { case main, novels }
    enum Tab: String, CaseIterable {
        case library, notebook, progress, settings
        case browse, updates, downloads, history
        var group: Group { [.browse, .updates, .downloads, .history].contains(self) ? .novels : .main }
        var title: String {
            ["library": "المكتبة", "notebook": "دفتري", "progress": "إنجازاتي", "settings": "الإعدادات",
             "browse": "تصفّح", "updates": "التحديثات", "downloads": "التحميلات", "history": "السجل"][rawValue]!
        }
        var icon: String {
            ["library": "books.vertical", "notebook": "book.closed", "progress": "trophy", "settings": "gearshape",
             "browse": "safari", "updates": "bell", "downloads": "arrow.down.circle", "history": "clock"][rawValue]!
        }
        static let main: [Tab] = [.library, .notebook, .progress, .settings]
        static let novels: [Tab] = [.browse, .updates, .downloads, .history]
    }

    /// pages pushed inside a tab
    enum Page: Hashable {
        case book(String)
        case novel(Int, String)
    }

    @Published var group: Group = .main
    @Published var mainTab: Tab = .library
    @Published var novelsTab: Tab = .browse
    @Published var paths: [Tab: [Page]] = [:]

    var tab: Tab { group == .main ? mainTab : novelsTab }

    func select(_ t: Tab) {
        if t == tab {
            // a second tap on the open tab goes back to its first page, as on iPhone
            if !(paths[t] ?? []).isEmpty { paths[t] = [] }
            return
        }
        group = t.group
        if t.group == .main { mainTab = t } else { novelsTab = t }
        Haptics.play("sel")
    }

    func path(_ t: Tab) -> Binding<[Page]> {
        Binding(get: { self.paths[t] ?? [] }, set: { self.paths[t] = $0 })
    }

    func push(_ p: Page, in t: Tab? = nil) {
        let t = t ?? tab
        paths[t, default: []].append(p)
    }

    /// A novel's page, in the tab you are in.
    func openNovel(_ id: Int, book: String) {
        guard id > 0 else { return }
        push(.novel(id, book))
    }

    /// The notebook, at a book (and a list).
    func openNotebook(book: String?, kind: String?) {
        NotebookNav.shared.show(book: book, kind: kind)
        group = .main
        mainTab = .notebook
        paths[.notebook] = []
    }
}

/// Short messages over everything (the web app's toast).
@MainActor
enum Toaster {
    static func show(_ text: String) {
        guard let w = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first,
              let root = w.rootViewController else { return }
        let top = NovelBridge.top(root)
        // over the reader (or another full screen): its own message; otherwise Jalees's toast above the tab bar
        if top !== root { Toast.show(text, in: top.view, bottom: 110) } else { ToastCenter.shared.show(text) }
    }
}
